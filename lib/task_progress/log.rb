# frozen_string_literal: true
# rbs_inline: enabled

require "securerandom"

class TaskProgress
  # The sequencer. Every change to a tree goes through `transaction`, which applies its events
  # under the one lock and commits them as a numbered Batch - so the lock is what puts the
  # changes from many threads into one order, and a batch is what crosses a process, a Ractor
  # or the wire as one piece.
  #
  # Outputs get the batches strictly in order, but outside that lock: a worker never waits on
  # another's output while it holds the tree. Delivery is synchronous to whoever committed, so
  # a slow output slows its committer down - wrap it in BufferedOutput when it must not
  class Log
    # The id its batches carry - ten lower case characters, unless given
    attr_reader :id #: String
    # The seq of the last batch it committed
    attr_reader :seq #: Integer
    # The stream key the tree is written to or read from, when it is - see TaskProgress.handoff
    attr_reader :key #: String?

    # Lower case only, like the task ids, so neither can clash with another on a filesystem that
    # ignores case (macOS, Windows) should one ever end up in a file name
    ID_CHARS = Ractor.make_shareable([*"0".."9", *"a".."z"]) #: Array[String]

    # @rbs @clock: ^() -> Float
    # @rbs @random: Random
    # @rbs @lock: Thread::Mutex
    # @rbs @delivery: Thread::Mutex
    # @rbs @state: State
    # @rbs @outputs: Array[output]
    # @rbs @outbox: Array[[Batch, Array[output]]]
    # @rbs @snapshot: State?
    # @rbs @touched: Set[path]
    # @rbs @on_cancel: Hash[path, Array[^(String?) -> void]]
    # @rbs @on_output_error: ^(Exception, untyped) -> void
    # @rbs @changed: Thread::ConditionVariable
    # @rbs @closers: Array[^() -> void]

    # An empty log. `clock` gives the time to stamp batches with, and `random` draws task ids - both for tests to pin down
    #: (?id: String | Symbol, ?key: String?, ?clock: ^() -> Float, ?random: Random) -> void
    def initialize(id: SecureRandom.alphanumeric(10, chars: ID_CHARS), key: nil, clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME) }, random: Random.new)
      @id = id.to_s
      @key = key
      @changed = ConditionVariable.new
      @closers = []
      @clock = clock
      @random = random
      @lock = Mutex.new
      @delivery = Mutex.new
      @state = State.new
      @seq = 0
      @outputs = [] #: Array[output]
      @outbox = []
      @snapshot = nil
      @touched = Set.new
      @on_cancel = {}
      @on_output_error = ->(error, output) { warn("TaskProgress: #{output.inspect} raised #{error.class}: #{error.message}") }
    end

    # Hears about an output that raised, with the error and the output; it warns by default
    attr_accessor :on_output_error #: ^(Exception, untyped) -> void

    # Runs the block under the lock, collecting what it adds with `tx.<<`; it commits as one
    # batch, or not at all if the block raises. A transaction opened inside another one on the
    # same fiber joins it. The block holds the lock throughout - keep it short, and never wait
    # in it on another thread that writes to this log
    #: [T] () { (Transaction) -> T } -> T
    def transaction
      if (tx = current)
        return yield(tx)
      end
      # An interrupt from Thread#raise (or Timeout) is let in only while the block runs, where a
      # rollback undoes it. Anywhere else it waits for the commit to finish, so the state and the
      # log can never part ways
      result = Thread.handle_interrupt(Exception => :never) do
        @lock.synchronize do
          opened = Transaction.new(@state, @clock.call, @random)
          self.current = opened
          begin
            value = Thread.handle_interrupt(Exception => :immediate) { yield(opened) }
            commit_locked(opened)
            value
          rescue Exception # rubocop:disable Lint/RescueException -- an interrupt rolls back as much as an error does
            @state.rollback(opened.journal)
            raise
          ensure
            self.current = nil
          end
        end
      end
      deliver
      result
    end

    # Commits the events as one batch
    #: (*Event) -> void
    def append(*events) = transaction { |tx| events.each { tx << it } }

    # An output is anything with `call(batch, log)`. Unless `replay: false`, it first gets the
    # tree so far as one squashed batch, `prev` 0, and then every batch after it. With a `path`
    # it gets only that subtree, as a tree of its own - see Branch
    #: (?output?, ?replay: bool, ?path: path) ?{ (Batch, Log) -> void } -> output
    def add_output(output = nil, replay: true, path: [], &block)
      # A block is a Proc, which is an output like any other
      output = output || (_ = block) || raise(ArgumentError, "An output, or a block")
      @lock.synchronize do
        target = path.empty? ? output : Branch.new(output, path.dup.freeze, @id, @seq)
        if replay && @state.key?(path)
          @outbox << [Batch.new(log: @id, prev: 0, seq: @seq, at: @clock.call, events: @state.squash(path).freeze), [target].freeze]
        end
        @outputs = [*@outputs, target].freeze
      end
      deliver
      output
    end

    # Takes the output as it was given to `add_output`
    #: (output) -> void
    def remove_output(output)
      @lock.synchronize { @outputs = @outputs.reject { it.equal?(output) || (it.is_a?(Branch) && it.output.equal?(output)) }.freeze }
    end

    # Calls the block with the reason once the task at `path` is canceled - at once, if it already
    # was. A task that ends any other way drops it. The block runs on whichever thread delivers
    # the cancel, after it has been committed: keep it short, and let it unblock the work (close a
    # connection, raise into a thread) rather than do the work
    #: (path) { (String?) -> void } -> void
    def on_cancel(path, &block)
      now = @lock.synchronize do
        node = @state[path]
        next false if node.nil? || (node.finished? && node.status != :canceled)
        next node.message || true if node.status == :canceled
        (@on_cancel[path] ||= []) << block
        false
      end
      block.call((now == true) ? nil : now) if now
    end

    # A frozen copy of the tree, safe to read from anywhere - and from inside an output too,
    # since outputs run outside the lock
    #: () -> State
    def snapshot
      return @state if @lock.owned?
      @lock.synchronize do
        snapshot = @snapshot
        if snapshot.nil? || @touched.any?
          snapshot = @snapshot = @state.snapshot(snapshot, (@touched if snapshot))
          @touched = Set.new
        end
        snapshot
      end
    end

    # The tree so far as one batch of puts - what a late reader starts from. With a `path`, the
    # subtree there, rooted at `[]` the way a Branch would send it
    #: (?path) -> Batch
    def squashed(path = [])
      @lock.synchronize do
        events = @state.squash(path).map { it.with(path: it.path.drop(path.length).freeze) }
        Batch.new(log: path.empty? ? @id : Branch.id(@id, path), prev: 0, seq: @seq, at: @clock.call, events: events.freeze)
      end
    end

    # Waits up to `timeout` seconds for a batch after `seq` to commit, and returns the seq then
    #: (Integer, Integer | Float) -> Integer
    def wait_for_change(seq, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @lock.synchronize do
        while @seq == seq && (left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
          @changed.wait(@lock, left)
        end
        @seq
      end
    end

    # Runs the block when the log is closed - to stop a thread that feeds it, or flush an output
    #: () { () -> void } -> void
    def on_close(&block) = @lock.synchronize { @closers << block }

    # Stops what was started for the tree - following a stream, beating, buffering - for when
    # nobody needs it any more. The tree itself stays as it is
    #: () -> void
    def close
      closers = @lock.synchronize { @closers.slice!(0..) || [] }
      closers.each(&:call)
    end

    # Its id and seq
    #: () -> String
    def inspect = "#<#{self.class} #{@id} seq=#{@seq}>"

    private

    #: () -> Transaction?
    def current = Thread.current[:task_progress_transactions]&.[](self)

    # Thread#[] is fiber-local and, unlike Fiber storage, a new thread or fiber does not inherit
    # it - which is what we want, since only the fiber that took the lock may join
    #: (Transaction?) -> void
    def current=(tx)
      fresh = {} #: Hash[Log, Transaction]
      map = (Thread.current[:task_progress_transactions] ||= fresh.compare_by_identity)
      tx ? map[self] = tx : map.delete(self)
    end

    #: (Batch) -> void
    def call_cancel_callbacks(batch)
      batch.events.each do |event|
        next unless %i[cancel done fail].include?(event.op)
        callbacks = @lock.synchronize { @on_cancel.delete(event.path) } or next
        next unless event.op == :cancel
        callbacks.each do |callback|
          callback.call(event.value)
        rescue => e
          @on_output_error.call(e, callback)
        end
      end
    end

    #: (Transaction) -> void
    def commit_locked(tx)
      # A transaction that changed a node without an event - sealing a mount - still changes what a snapshot shows
      @touched.merge(tx.journal.paths)
      return if tx.events.empty?
      batch = Batch.new(log: @id, prev: @seq, seq: @seq + 1, at: tx.at, events: tx.events.freeze)
      @seq = batch.seq
      @outbox << [batch, @outputs]
      @changed.broadcast
    end

    # One deliverer at a time, taking the outbox in order. A commit made from inside an output
    # finds its own fiber already delivering, and leaves its batch for the loop it is inside of
    #
    # Each batch goes to all its outputs with interrupts held off, so one can never reach some
    # outputs and not others. An interrupt waits for the batch in hand, not for the whole outbox
    #: () -> void
    def deliver
      return if @delivery.owned?
      @delivery.synchronize do
        loop do
          delivered = Thread.handle_interrupt(Exception => :never) do
            entry = @lock.synchronize { @outbox.shift } or next false
            batch, outputs = entry
            outputs.each do |output|
              output.call(batch, self)
            rescue => e
              @on_output_error.call(e, output)
            end
            call_cancel_callbacks(batch) unless @on_cancel.empty?
            true
          end
          break unless delivered
        end
      end
    end
  end
end
