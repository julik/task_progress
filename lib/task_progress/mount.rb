# frozen_string_literal: true
# rbs_inline: enabled

require "json"

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

    # @rbs @control: IO?
    # @rbs @last_seq: Integer?
    # @rbs @control_lock: Thread::Mutex
    # @rbs @source: String?
    # @rbs @stale: bool
    # @rbs @remote_ended: bool
    # @rbs @controlled: bool
    # @rbs @own: bool
    # @rbs @following: bool
    # @rbs @forward: (^(String) -> void)?
    # @rbs @reader: StreamReader?
    # @rbs @follower: Thread?
    # @rbs @stopping: bool
    # @rbs @silent: bool
    # @rbs @gave_up: bool
    # @rbs @generation: Integer

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
      @gave_up = false
      @generation = 0
      @control = nil
      @control_lock = Mutex.new
      @source = nil
      @last_seq = nil
      @stale = false
      @remote_ended = false
      @controlled = false
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
    #: (Batch | Hash[untyped, untyped] | String) -> Symbol
    def <<(batch)
      batch = coerce(batch) or return :rejected
      starting_over = false
      # Judged and applied in one transaction: a cancel or another batch arriving at the same
      # moment comes wholly before this one or wholly after it
      # It happened when the remote committed it. A pipe or a port is fresh news, so its clock is
      # moved onto ours by the gap between the two; a stream hands on what may have been written
      # long ago, by a machine whose clock is taken to agree with ours
      at = (@following && batch.at.positive?) ? batch.at : nil
      outcome = @log.transaction(at:) do |tx|
        node = tx.state[@path] or next :rejected
        source = @source
        last_seq = @last_seq
        new_run = batch.reset? && !source.nil? && batch.log != source
        # A run given up on as lost that turns out alive is taken back, from a fresh squash
        starting_over = @following && batch.reset? && (new_run || @gave_up)
        if node.finished? && !starting_over
          # Ended here - what the remote sent on its way out changes nothing. A lost run that
          # speaks again gets read afresh, see above
          next (@following && @gave_up && batch.log == source) ? :gap : :rejected
        end
        if batch.log == source && last_seq && batch.seq <= last_seq && !starting_over
          # Said again - after a reconnect, a replay, or a resync to a snapshot it has since passed
          next :duplicate
        elsif @following && !batch.reset? && batch.log != source
          next :superseded
        elsif !batch.reset? && (batch.log != source || batch.prev != last_seq)
          mark_stale(tx)
          next :gap
        end
        offset = (!@following && batch.at.positive?) ? tx.at - batch.at : 0.0
        events = translate(batch.events, offset) or next :rejected
        events.unshift(Event.new(path: @path, op: :prune)) if batch.reset?
        events.unshift(Event.new(path: @path, op: :put, value: fresh(tx.state))) if new_run || starting_over
        events.each { tx << it }
        tx << Event.new(path: @path, op: :meta, value: {stale: false}) if @stale
        # Known before the batch is delivered, so an output that sees the mount end can tell who ended it
        @remote_ended = false if starting_over
        @remote_ended ||= batch.events.any? { it.path.empty? && (ENDINGS.include?(it.op) || (it.op == :put && FINISHED.include?(it.value[:status]))) }
        @source = batch.log
        @last_seq = batch.seq
        @stale = false
        @silent = false
        @gave_up = false
        :applied
      end
      # The run before may have ended, and its cancel went with it
      arm_cancel if outcome == :applied && starting_over
      outcome
    rescue ArgumentError
      :rejected
    end

    # Reads NDJSON batches off an IO until EOF
    #: (IO) -> self
    def read(io)
      Wire.each_batch(io) { self << it }
      self
    end

    # Two pipes for a child process to report up and take cancel requests from - see Pipes.
    # With a block, they are closed once it returns
    #: () -> Pipes
    #: [T] () { (Pipes) -> T } -> T
    def pipes
      pipes = Pipes.new(self)
      return pipes unless block_given?
      begin
        yield pipes
      ensure
        pipes.close
      end
    end

    # Cancel requests go down `io` from now on - see Pipes
    #: (IO) -> void
    def take_control(io) # :nodoc:
      @control_lock.synchronize do
        previous = @control
        previous.close unless previous.nil? || previous.closed?
        @control = io
      end
      @controlled = true
      arm_cancel
    end

    # Closes `io`, if cancel requests still go down it
    #: (IO) -> void
    def release_control(io) # :nodoc:
      @control_lock.synchronize do
        next unless @control.equal?(io)
        io.close unless io.closed?
        @control = nil
        @controlled = false
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
      arm_cancel
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
    def catch_up(timeout: nil) # :nodoc:
      reader = @reader or raise ArgumentError, "Not following a stream - see #follow_stream"
      reader.read(timeout:).count do |batch|
        outcome = self << batch
        reader.resync! if outcome == :gap
        outcome == :applied
      end
    end

    # Stops following, see #follow_stream - closing the log does it
    #: () -> void
    def stop_following # :nodoc:
      @stopping = true
      @follower&.join unless @follower == Thread.current
    end

    # Passes a cancel request on to the child, for the task at `path` in its own tree. Returns
    # :forwarded, or :moot when there is no child to ask any more - it has exited, or this mount
    # never had one. Whether the child cancels anything shows up the stream, if it does
    #: (path, ?String?) -> (:forwarded | :moot)
    def request_cancel(path, reason = nil) # :nodoc:
      # Over a stream, a request names the run it is for, so it cannot reach another one by mistake
      line = JSON.generate({cancel: path, reason:, run: (@source if @following)}.compact) + "\n"
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

    private

    # The parent may still end the subtree - when the remote went away, say. From outside, end
    # the mount's own task: `mount.task.done!`
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

    #: (Integer | Float, Integer | Float) -> void
    def watch(poll, give_up_after)
      reader = @reader or return
      beating = false
      silent_since = nil #: Float?
      until @stopping
        begin
          catch_up(timeout: poll)
          status = @log.snapshot[@path]&.status
          break if status == :done || status == :canceled
          if reader.alive?
            beating = true
            silent_since = nil
            speaks_again if @silent
            # Given up on, and alive after all: read it afresh
            reader.resync! if @gave_up
          elsif beating && status != :failed
            since = silent_since ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
            @silent = true
            mark_stale
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) - since >= give_up_after
              @gave_up = true
              fail!("Lost touch with whoever was working on it")
              beating = false
            end
          end
        rescue => e
          # The stream is away for a moment, say - keep trying, and say so
          @log.on_error.call(e, self)
          sleep(poll)
        end
      end
    end

    # Canceling the mount asks the remote to cancel its root - the run there is now, once
    #: () -> void
    def arm_cancel
      generation = @generation += 1
      task.on_cancel { |reason| request_cancel([], reason) if generation == @generation && !@remote_ended }
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

    # In the transaction given, or one of its own
    #: (?Transaction?) -> void
    def mark_stale(tx = nil)
      return if @stale
      @stale = true
      event = Event.new(path: @path, op: :meta, value: {stale: true})
      tx ? tx << event : @log.append(event)
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
