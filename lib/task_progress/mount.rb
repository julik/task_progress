# frozen_string_literal: true

require "rbconfig"

class TaskProgress
  # Grafts a tree that lives elsewhere under one node of this one. The remote root lands on the
  # mount node itself and its `["x3k0"]` on `[*mount, "x3k0"]`, so mounting is prefixing, and
  # a relay through several processes prefixes once per hop.
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
      return :rejected if finished? # ended here - what the remote sent on its way out changes nothing
      if batch.log == @source && !batch.reset? && batch.seq <= @last_seq
        return :duplicate
      elsif !batch.reset? && (batch.log != @source || batch.prev != @last_seq)
        mark_stale
        return :gap
      end
      # Known before the batch commits, so an output that sees the mount end can tell who ended it
      @remote_ended ||= batch.events.any? { it.path.empty? && (ENDINGS.include?(it.op) || (it.op == :put && FINISHED.include?(it.value[:status]))) }
      applied = @log.transaction do |tx|
        # The remote's times are on its clock. Its batch says what that clock read when it
        # committed, so the gap to ours moves them over - give or take the time in transit
        offset = batch.at.positive? ? tx.at - batch.at : 0.0
        events = translate(batch.events, offset) or next false
        events.unshift(Event.new(path: @path, op: :prune)) if batch.reset?
        events.each { tx << it }
        tx << Event.new(path: @path, op: :meta, value: {stale: false}) if @stale
        true
      end
      return :rejected unless applied
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
    # Interrupted (Ctrl-C, a timeout), it terminates the child and cancels or fails the mount. So
    # does the mount being canceled or failed from here - by `cancel!` on a task above it, say -
    # while the child is still at it
    def spawn(*command, **options)
      reader, writer = IO.pipe
      env = command.first.is_a?(Hash) ? command.shift : {}
      status = nil
      pid = Process.spawn({**env, "TASK_PROGRESS_FD" => "3"}, *command, 3 => writer, **options)
      writer.close
      stop = ->(batch, _log) do
        next if @remote_ended || batch.events.none? { it.path == @path && (it.op == :cancel || it.op == :fail) }
        Process.kill(:TERM, pid)
      rescue Errno::ESRCH
        nil
      end
      @log.add_output(stop, replay: false)
      follow(reader)
      @log.remove_output(stop) # before the child is reaped, so its pid is never signaled once reused
      _, status = Process.wait2(pid)
      fail!("#{File.basename(command.first.to_s)} exited with #{status.exitstatus || status.termsig}") unless status.success?
      fail!("#{File.basename(command.first.to_s)} exited without finishing") unless finished?
      status
    rescue Interrupt => e
      cancel!(e.message == "Interrupt" ? nil : e.message)
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      fail!(e)
      raise
    ensure
      @log.remove_output(stop) if stop
      reader&.close
      writer&.close unless writer&.closed?
      if pid && status.nil?
        Process.kill(:TERM, pid) rescue Errno::ESRCH
        Process.wait(pid) rescue Errno::ECHILD
      end
    end

    # The parent may still end the subtree - when the remote went away, say
    def done!
      finish(:done) { |tx| tx << Event.new(path: @path, op: :done) }
    end

    def fail!(error = nil, **extra)
      finish(:cancel) do |tx|
        tx << Event.new(path: @path, op: :fail, value: Wire.error_to_h(error || "#{tx.state[@path].name} failed").merge(extra))
      end
    end

    def cancel!(reason = nil)
      finish(:cancel) { |tx| tx << Event.new(path: @path, op: :cancel, value: (TaskProgress.utf8(reason.to_s) if reason)) }
    end

    def finished? = task.finished?

    private

    # Ending the mount ends what the remote left open under it too, as Task#done! and #fail! do
    def finish(closing)
      @log.transaction do |tx|
        next if tx.state[@path].finished?
        tx.state.open_under(@path).reverse_each { tx << Event.new(path: it, op: closing) }
        yield tx
      end
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

    def translate(events, offset)
      events.map do |event|
        path = [*@path, *event.path]
        return nil if path.length > Wire::MAX_DEPTH
        value = (event.op == :put) ? rebased(event.value, offset) : event.value
        # A remote's own tasks cannot be called off from here - nothing carries a cancel back to it
        value = value.except(:cancelable) if %i[open meta put].include?(event.op)
        next Event.new(path:, op: event.op, value:) unless event.path.empty?
        case event.op
        when :open, :meta then Event.new(path:, op: :meta, value: value.except(:name, :weight))
        when :put then Event.new(path:, op: :put, value: own_put(value))
        else Event.new(path:, op: event.op, value:)
        end
      end
    end

    TIMES = %i[opened_at started_at finished_at].freeze
    ENDINGS = %i[done fail cancel].freeze
    FINISHED = %i[done failed canceled].freeze

    def rebased(value, offset)
      return value if offset.zero?
      value.merge(value.slice(*TIMES).compact.transform_values { it + offset })
    end

    def own_put(value)
      node = @log.snapshot[@path]
      value.merge(name: node.name, weight: node.weight, cancelable: node.cancelable).compact
    end
  end
end
