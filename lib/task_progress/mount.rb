# frozen_string_literal: true
# rbs_inline: enabled

require "json"
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
  # until a batch with `prev` 0 replaces it whole.
  #
  # Fed from a stream (see #follow_stream) it goes by the latest writer instead: a batch with
  # `prev` 0 from a log it has not seen is a new run - a job retried, a worker that took over -
  # and replaces the subtree whole, even one that had finished, while what the old writer still
  # sends is ignored
  class Mount
    # The log the mount node lives in
    attr_reader :log #: Log
    # The mount node
    attr_reader :path #: path
    # The seq of the remote's last batch it applied
    attr_reader :last_seq #: Integer?

    # @rbs @control: IO?
    # @rbs @control_lock: Thread::Mutex
    # @rbs @pid_lock: Thread::Mutex
    # @rbs @source: String?
    # @rbs @stale: bool
    # @rbs @remote_ended: bool
    # @rbs @controlled: bool
    # @rbs @reaped: bool
    # @rbs @own: bool
    # @rbs @following: bool
    # @rbs @forward: (^(String) -> void)?
    # @rbs @reader: StreamReader?
    # @rbs @follower: Thread?
    # @rbs @stopping: bool
    # @rbs @silent: bool

    # For the node at `path` - see TaskProgress#mount, which opens one. Unless `own`, the
    # remote's root names and weighs the mount node too - for a tree that is nothing but a mount,
    # as TaskProgress.follow makes
    #: (Log, path, ?own: bool) -> void
    def initialize(log, path, own: true)
      @log = log
      @path = path
      @own = own
      @following = false
      @forward = nil
      @reader = nil
      @follower = nil
      @stopping = false
      @silent = false
      @control = nil
      @control_lock = Mutex.new
      @pid_lock = Mutex.new
      @source = nil
      @last_seq = nil
      @stale = false
      @remote_ended = false
      @controlled = false
      @reaped = false
    end

    # The mount node, as a task of this tree
    #: () -> TaskProgress
    def task = TaskProgress.handle(@log, @path)

    # Whether a batch went missing, and the subtree waits for a fresh squash
    #: () -> bool
    def stale? = @stale

    # Takes a Batch, its Hash form, or a line of NDJSON. Returns :applied, :gap, :rejected, or
    # :duplicate for one already applied - redelivery is ordinary after a reconnect or a replay.
    # Following a stream, a batch from a writer another has since replaced is :superseded
    #: (Batch | Hash[untyped, untyped] | String) -> (:applied | :gap | :rejected | :duplicate | :superseded)
    def <<(batch)
      batch = coerce(batch) or return :rejected
      new_run = batch.reset? && !@source.nil? && batch.log != @source
      # Ended here - what the remote sent on its way out changes nothing. But a new run starts over
      return :rejected if finished? && !(@following && new_run)
      last_seq = @last_seq
      if batch.log == @source && !batch.reset? && last_seq && batch.seq <= last_seq
        return :duplicate
      elsif @following && !batch.reset? && batch.log != @source
        return :superseded
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
        events.unshift(Event.new(path: @path, op: :put, value: fresh(tx.state))) if new_run
        events.each { tx << it }
        tx << Event.new(path: @path, op: :meta, value: {stale: false}) if @stale
        true
      end
      return :rejected unless applied
      @source = batch.log
      @last_seq = batch.seq
      @stale = false
      @silent = false
      :applied
    rescue ArgumentError
      :rejected
    end

    # Reads NDJSON batches off an IO until EOF
    #: (IO) -> self
    def follow(io)
      Wire.each_batch(io) { self << it }
      self
    end

    # Runs a command with TASK_PROGRESS_FD pointing at a pipe, follows it until it exits, and
    # returns its Process::Status. A child that exits without finishing its root fails the mount.
    #
    # A second pipe, TASK_PROGRESS_CONTROL_FD, carries cancel requests the other way, so tasks in
    # the child can be canceled from here - see #request_cancel; TaskProgress.cli reads it. When
    # the mount itself is canceled, the child is asked to cancel its root, and is sent TERM if it
    # is still running `grace` seconds later. Interrupted (Ctrl-C, a timeout), it terminates the
    # child at once
    #: (*untyped command, ?grace: Integer | Float, **untyped options) -> Process::Status?
    def spawn(*command, grace: 5, **options)
      reader, writer = IO.pipe
      control_reader, @control = IO.pipe
      env = command.first.is_a?(Hash) ? command.shift : {} #: Hash[String, String]
      status = nil
      @reaped = false
      pid = Process.spawn({**env, "TASK_PROGRESS_FD" => "3", "TASK_PROGRESS_CONTROL_FD" => "4"}, *command,
        3 => writer, 4 => control_reader, **options)
      writer.close
      control_reader.close
      @controlled = true
      task.on_cancel { stop(pid, grace) unless @remote_ended }
      follow(reader)
      status = reap(pid)
      fail!("#{File.basename(command.first.to_s)} exited with #{status.exitstatus || status.termsig}") if status && !status.success?
      fail!("#{File.basename(command.first.to_s)} exited without finishing") unless finished?
      status
    rescue Interrupt => e
      cancel!(TaskProgress.interrupted_by(e))
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      fail!(e)
      raise
    ensure
      @controlled = false
      @control_lock.synchronize { @control&.close unless @control&.closed? }
      reader&.close
      writer&.close unless writer&.closed?
      if pid && status.nil?
        signal(pid, :TERM)
        reap(pid)
      end
    end

    # Follows the tree a StreamOutput writes to `stream` at `key` - what TaskProgress.handoff and
    # TaskProgress.adopt write - on a thread of its own, checking every `poll` seconds. Cancel
    # requests go back to the writer through the stream, and canceling the mount asks the writer
    # to cancel its root.
    #
    # It also minds whether the writer is alive. Once one has been, a writer that stops beating
    # marks the subtree stale, and fails the mount if it stays silent for `give_up_after`
    # seconds - unless a new run comes along later and replaces it, as a retried job does. A
    # tree nobody has taken up yet is waiting, not silent. Following ends once the mount is done
    # or canceled, or the log is closed - a failed one is kept an eye on, for a retry
    #
    # With `watch: false` it takes what is there once, and leaves catching up again to
    # #catch_up - for a tree read once, see TaskProgress.fetch
    #: (untyped, String, ?poll: Integer | Float, ?give_up_after: Integer | Float, ?watch: bool) -> self
    def follow_stream(stream, key, poll: 1, give_up_after: 60, watch: true)
      @following = true
      @controlled = true
      @reader = StreamReader.new(stream, key)
      @forward = ->(line) { stream.append(StreamOutput.control_key(key), line) }
      task.on_cancel { |reason| request_cancel([], reason) unless @remote_ended }
      catch_up
      # Read once, a tree that is under way with nobody beating for it can only be a lost one
      mark_stale if !watch && @log.snapshot[@path]&.status == :active && !@reader&.alive?
      return self unless watch
      @log.on_close { stop_following }
      @follower = Thread.new do
        Thread.current.report_on_exception = false
        watch(poll, give_up_after)
      end
      self
    end

    # Takes what the stream has for it - waiting up to `timeout` seconds when it has nothing yet -
    # and returns how many batches it applied. #follow_stream does this over and over
    #: (?timeout: (Integer | Float)?) -> Integer
    def catch_up(timeout: nil)
      reader = @reader or raise ArgumentError, "Not following a stream - see #follow_stream"
      reader.read(timeout:).count do |batch|
        outcome = self << batch
        reader.resync! if outcome == :gap
        outcome == :applied
      end
    end

    # Stops following, see #follow_stream
    #: () -> void
    def stop_following
      @stopping = true
      @follower&.join unless @follower == Thread.current
    end

    # Passes a cancel request on to the child, for the task at `path` in its own tree. Returns
    # :forwarded, or :moot when there is no child to ask any more - it has exited, or this mount
    # was never spawned. Whether the child cancels anything shows up the stream, if it does
    #: (path, ?String?) -> (:forwarded | :moot)
    def request_cancel(path, reason = nil)
      line = JSON.generate({cancel: path, reason:}.compact) + "\n"
      if (forward = @forward)
        forward.call(line)
        return :forwarded
      end
      @control_lock.synchronize do
        control = @control
        return :moot if control.nil? || control.closed?
        control.write_nonblock(line) # a child too stuck to read its requests is past asking
      end
      :forwarded
    rescue IO::WaitWritable, IOError, SystemCallError
      :moot
    end

    # The parent may still end the subtree - when the remote went away, say
    #: () -> self
    def done!
      finish(:done) { |tx| tx << Event.new(path: @path, op: :done) }
    end

    # Fails the mount, and cancels what the remote left open under it
    #: (?(Exception | String)?, **bool | Integer) -> self
    def fail!(error = nil, **extra)
      finish(:cancel) do |tx|
        tx << Event.new(path: @path, op: :fail, value: Wire.error_to_h(error || "#{tx.state[@path]&.name} failed").merge(extra))
      end
    end

    # Cancels the mount, and what the remote left open under it
    #: (?String?) -> self
    def cancel!(reason = nil)
      finish(:cancel) { |tx| tx << Event.new(path: @path, op: :cancel, value: (TaskProgress.utf8(reason.to_s) if reason)) }
    end

    # Whether the mount node has ended
    #: () -> bool
    def finished? = task.finished?

    private

    #: (Integer | Float, Integer | Float) -> void
    def watch(poll, give_up_after)
      reader = @reader or return
      beating = false
      silent_since = nil #: Float?
      until @stopping
        catch_up(timeout: poll)
        status = @log.snapshot[@path]&.status
        break if status == :done || status == :canceled
        if reader.alive?
          beating = true
          silent_since = nil
          speaks_again if @silent
        elsif beating && status != :failed
          since = silent_since ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @silent = true
          mark_stale
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) - since >= give_up_after
            fail!("Lost touch with whoever was working on it")
            beating = false
          end
        end
      end
    rescue => e
      @log.on_output_error.call(e, self)
    end

    # The writer beats again, and nothing went missing meanwhile
    #: () -> void
    def speaks_again
      @silent = false
      return unless @stale
      @stale = false
      @log.append(Event.new(path: @path, op: :meta, value: {stale: false}))
    end

    # The mount node as a new run finds it: its own name and weight, nothing done yet
    #: (State) -> Hash[Symbol, untyped]
    def fresh(state)
      node = state[@path] or return {name: "", status: :pending}
      {name: node.name, weight: node.weight, cancelable: (node.cancelable if @own), status: :pending}.compact
    end

    # Ending the mount ends what the remote left open under it too, as Task#done! and #fail! do
    #: (Symbol) { (Transaction) -> void } -> self
    def finish(closing)
      @log.transaction do |tx|
        next if tx.state[@path]&.finished?
        tx.state.open_under(@path).reverse_each { tx << Event.new(path: it, op: closing) }
        yield tx
      end
      self
    end

    #: (Batch | Hash[untyped, untyped] | String) -> Batch?
    def coerce(batch)
      case batch
      when Batch then batch
      when Hash then Wire.from_h(batch)
      when String then Wire.parse(batch)
      end
    end

    #: () -> void
    def mark_stale
      return if @stale
      @stale = true
      @log.append(Event.new(path: @path, op: :meta, value: {stale: true}))
    end

    # The remote's events, moved under the mount - or nil if one would land too deep
    #: (Array[Event], Float) -> Array[Event]?
    def translate(events, offset)
      events.map do |event|
        path = [*@path, *event.path]
        return nil if path.length > Wire::MAX_DEPTH
        value = (event.op == :put) ? rebased(event.value, offset) : event.value
        # Without a control pipe nothing carries a cancel back to the remote, so none of its own
        # tasks can be offered for cancelling from here
        value = value.except(:cancelable) if !@controlled && %i[open meta put].include?(event.op)
        next Event.new(path:, op: event.op, value:) unless event.path.empty?
        next Event.new(path:, op: (event.op == :open) ? :meta : event.op, value:) unless @own
        case event.op
        when :open, :meta then Event.new(path:, op: :meta, value: value.except(:name, :weight))
        when :put then Event.new(path:, op: :put, value: own_put(value))
        else Event.new(path:, op: event.op, value:)
        end
      end
    end

    # Asks the child to cancel its root, and sends TERM if it has not exited `grace` seconds on
    #: (Integer, Integer | Float) -> void
    def stop(pid, grace)
      request_cancel([], task.message)
      Thread.new do
        sleep(grace)
        signal(pid, :TERM)
      end
    end

    # The pid is only ever signaled while it is still ours: reaping and signaling share a lock, so
    # a signal can never reach another process that was given the pid after ours exited
    #: (Integer, Symbol) -> void
    def signal(pid, name)
      @pid_lock.synchronize { Process.kill(name, pid) unless @reaped }
    rescue Errno::ESRCH
      nil
    end

    #: (Integer) -> Process::Status?
    def reap(pid)
      @pid_lock.synchronize do
        _, status = Process.wait2(pid)
        @reaped = true
        status
      end
    rescue Errno::ECHILD
      @reaped = true
      nil
    end

    TIMES = %i[opened_at started_at finished_at].freeze #: Array[Symbol]
    ENDINGS = %i[done fail cancel].freeze #: Array[Symbol]
    FINISHED = %i[done failed canceled].freeze #: Array[Symbol]
    private_constant :TIMES, :ENDINGS, :FINISHED

    #: (Hash[Symbol, untyped], Float) -> Hash[Symbol, untyped]
    def rebased(value, offset)
      return value if offset.zero?
      value.merge(value.slice(*TIMES).compact.transform_values { it + offset })
    end

    #: (Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
    def own_put(value)
      node = @log.snapshot[@path] or return value
      value.merge(name: node.name, weight: node.weight, cancelable: node.cancelable).compact
    end
  end
end
