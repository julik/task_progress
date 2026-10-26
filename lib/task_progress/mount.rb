# frozen_string_literal: true

require "rbconfig"

class TaskProgress
  # Grafts a tree that lives elsewhere under one node of this one. The remote root lands on the
  # mount node itself and its `[1, 4]` on `[*mount, 1, 4]`, so mounting is prefixing, and a
  # relay through several processes prefixes once per hop.
  #
  # The mount node is sealed: only its Mount writes under it, so a remote can never touch a
  # node outside its prefix - nor rename or reweigh the mount, which stay the parent's to set.
  # Each remote batch is re-committed here as one batch, or dropped whole if it does not apply.
  # A batch that does not follow the last one (a gap) marks the subtree stale, and it stays so
  # until a batch with `prev` 0 replaces it whole
  class Mount
    attr_reader :log, :path, :last_seq

    def initialize(log, path)
      @log = log
      @path = path
      @source = nil
      @last_seq = nil
      @stale = false
    end

    def task = TaskProgress.handle(@log, @path)

    def stale? = @stale

    # Takes a Batch, its Hash form, or a line of NDJSON. Returns :applied, :gap, :rejected, or
    # :duplicate for one already applied - redelivery is ordinary after a reconnect or a replay
    def <<(batch)
      batch = coerce(batch) or return :rejected
      if batch.reset?
        events = [Event.new(path: @path, op: :prune), *translate(batch.events)]
      elsif batch.log == @source && batch.seq <= @last_seq
        return :duplicate
      elsif batch.log != @source || batch.prev != @last_seq
        mark_stale
        return :gap
      else
        events = translate(batch.events)
      end
      return :rejected if events.nil?
      @log.transaction do |tx|
        events.each { tx << it }
        tx << Event.new(path: @path, op: :meta, value: {stale: false}) if @stale
      end
      @source = batch.log
      @last_seq = batch.seq
      @stale = false
      :applied
    rescue ArgumentError
      :rejected
    end

    # Reads NDJSON batches off an IO until EOF
    def follow(io)
      Wire.each_batch(io) { self << it }
      self
    end

    # Runs a command with TASK_PROGRESS_FD pointing at a pipe, follows it until it exits, and
    # returns its Process::Status. A child that exits without finishing its root fails the mount.
    # Interrupted (a cancel, a timeout), it terminates the child and fails the mount with the error
    def spawn(*command, **options)
      reader, writer = IO.pipe
      env = command.first.is_a?(Hash) ? command.shift : {}
      status = nil
      pid = Process.spawn({**env, "TASK_PROGRESS_FD" => "3"}, *command, 3 => writer, **options)
      writer.close
      follow(reader)
      _, status = Process.wait2(pid)
      fail!("#{File.basename(command.first.to_s)} exited with #{status.exitstatus || status.termsig}") unless status.success?
      fail!("#{File.basename(command.first.to_s)} exited without finishing") unless finished?
      status
    rescue Exception => e # rubocop:disable Lint/RescueException
      fail!(e)
      raise
    ensure
      reader&.close
      writer&.close unless writer&.closed?
      if pid && status.nil?
        Process.kill(:TERM, pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
    end

    # The parent may still end the subtree - when the remote went away, say
    def done!
      finish { |tx| tx << Event.new(path: @path, op: :done) }
    end

    def fail!(error = nil, **extra)
      finish do |tx|
        tx << Event.new(path: @path, op: :fail, value: Wire.error_to_h(error || "#{tx.state[@path].name} failed").merge(extra))
      end
    end

    def finished? = task.finished?

    private

    def finish
      @log.transaction { |tx| yield tx unless tx.state[@path].finished? }
      self
    end

    def coerce(batch)
      case batch
      when Batch then batch
      when Hash then Wire.from_h(batch)
      when String then Wire.parse(batch)
      end
    end

    def mark_stale
      return if @stale
      @stale = true
      @log.append(Event.new(path: @path, op: :meta, value: {stale: true}))
    end

    def translate(events)
      events.map do |event|
        path = [*@path, *event.path]
        return nil if path.length > Wire::MAX_DEPTH
        next Event.new(path:, op: event.op, value: event.value) unless event.path.empty?
        case event.op
        when :open then Event.new(path:, op: :meta, value: event.value.except(:name, :weight))
        when :meta then Event.new(path:, op: :meta, value: event.value.except(:name, :weight))
        when :put then Event.new(path:, op: :put, value: own_put(event.value))
        when :prune then Event.new(path:, op: :prune)
        else Event.new(path:, op: event.op, value: event.value)
        end
      end
    end

    def own_put(value)
      node = @log.snapshot[@path]
      value.merge(name: node.name, weight: node.weight)
    end
  end
end
