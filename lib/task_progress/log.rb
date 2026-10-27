# frozen_string_literal: true

require "securerandom"

class TaskProgress
  # The sequencer. Every change to a tree goes through `transaction`, which applies its events
  # under the one lock and commits them as a numbered Batch - so the lock is what puts the
  # changes from many threads into one order, and a batch is what crosses a process, a Ractor
  # or the wire as one piece.
  #
  # Outputs get the batches strictly in order, but outside that lock: a worker never waits on
  # another's output while it holds the tree. Delivery is synchronous to whoever committed, so
  # a slow output slows its committer down - wrap it in Outputs::Buffered when it must not
  class Log
    attr_reader :id, :seq

    def initialize(id: SecureRandom.alphanumeric(10), clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME) })
      @id = id.to_s
      @clock = clock
      @lock = Mutex.new
      @delivery = Mutex.new
      @state = State.new
      @seq = 0
      @outputs = [].freeze
      @outbox = []
      @snapshot = nil
      @on_output_error = ->(error, output) { warn("TaskProgress: #{output.inspect} raised #{error.class}: #{error.message}") }
    end

    attr_writer :on_output_error

    # Runs the block under the lock, collecting what it adds with `tx.<<`; it commits as one
    # batch, or not at all if the block raises. A transaction opened inside another one on the
    # same fiber joins it. The block holds the lock throughout - keep it short, and never wait
    # in it on another thread that writes to this log
    def transaction
      if (tx = current)
        return yield(tx)
      end
      # An interrupt from Thread#raise (or Timeout) is let in only while the block runs, where a
      # rollback undoes it. Anywhere else it waits for the commit to finish, so the state and the
      # log can never part ways
      result = Thread.handle_interrupt(Exception => :never) do
        @lock.synchronize do
          tx = Transaction.new(@state, @clock.call)
          self.current = tx
          begin
            value = Thread.handle_interrupt(Exception => :immediate) { yield(tx) }
            commit_locked(tx)
            value
          rescue Exception
            @state.rollback(tx.journal)
            raise
          ensure
            self.current = nil
          end
        end
      end
      deliver
      result
    end

    def append(*events) = transaction { |tx| events.each { tx << it } }

    # An output is anything with `call(batch, log)`. Unless `replay: false`, it first gets the
    # tree so far as one squashed batch, `prev` 0, and then every batch after it. With a `path`
    # it gets only that subtree, as a tree of its own - see Branch
    def add_output(output = nil, replay: true, path: [], &block)
      output ||= block
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
    def remove_output(output)
      @lock.synchronize { @outputs = @outputs.reject { it == output || (it.is_a?(Branch) && it.output == output) }.freeze }
    end

    # A frozen copy of the tree, safe to read from anywhere - and from inside an output too,
    # since outputs run outside the lock
    def snapshot
      return @state if @lock.owned?
      @lock.synchronize { @snapshot = nil if @snapshot&.first != @seq; (@snapshot ||= [@seq, @state.snapshot]).last }
    end

    # The tree so far as one batch of puts - what a late reader starts from. With a `path`, the
    # subtree there, rooted at `[]` the way a Branch would send it
    def squashed(path = [])
      @lock.synchronize do
        events = @state.squash(path).map { it.with(path: it.path.drop(path.length).freeze) }
        Batch.new(log: path.empty? ? @id : Branch.id(@id, path), prev: 0, seq: @seq, at: @clock.call, events: events.freeze)
      end
    end

    def inspect = "#<#{self.class} #{@id} seq=#{@seq}>"

    class Transaction
      attr_reader :events, :journal, :at, :state

      def initialize(state, at)
        @state = state
        @at = at
        @events = []
        @journal = State::Journal.new
      end

      def <<(event)
        @state.apply(event, at: @at, journal: @journal)
        @events << event
        self
      end
    end

    private

    def current = Thread.current[:task_progress_transactions]&.[](self)

    # Thread#[] is fiber-local and, unlike Fiber storage, a new thread or fiber does not inherit
    # it - which is what we want, since only the fiber that took the lock may join
    def current=(tx)
      map = (Thread.current[:task_progress_transactions] ||= {}.compare_by_identity)
      tx ? map[self] = tx : map.delete(self)
    end

    def commit_locked(tx)
      return if tx.events.empty?
      batch = Batch.new(log: @id, prev: @seq, seq: @seq + 1, at: tx.at, events: tx.events.freeze)
      @seq = batch.seq
      @outbox << [batch, @outputs]
    end

    # One deliverer at a time, taking the outbox in order. A commit made from inside an output
    # finds its own fiber already delivering, and leaves its batch for the loop it is inside of
    #
    # Each batch goes to all its outputs with interrupts held off, so one can never reach some
    # outputs and not others. An interrupt waits for the batch in hand, not for the whole outbox
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
            true
          end
          break unless delivered
        end
      end
    end
  end
end
