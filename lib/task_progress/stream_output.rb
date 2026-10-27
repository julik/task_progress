# frozen_string_literal: true
# rbs_inline: enabled

require "json"

class TaskProgress
  # Writes a tree to a stream - a MemoryStreamStore, a RedisStreamStore - for readers anywhere to follow
  # with StreamReader. What TaskProgress.handoff and TaskProgress.adopt write through. Under one
  # key it keeps:
  #
  #     key            every batch, one entry each
  #     key:run        the log id of the run that writes the tree now
  #     key:snapshot   the tree squashed into one batch, and the id of the entry it is as of -
  #                    where a reader starts, so the stream before it can be trimmed away
  #     key:beat       there while the run is alive, and gone a few seconds after it is not
  #     key:control    cancel requests, the other way - see Mount#follow_stream
  #
  # **One run at a time.** Each writer is a run, named by its log id, and claims `key:run` with its
  # first batch. A run that a later one has taken over from - a job retried while the first
  # attempt still limps on, two workers that adopted at once - may still append, and readers
  # ignore what it appends; but every snapshot, trim, beat and expiry is written only while
  # `key:run` still names the run that writes it, checked and written in one step. So a run that
  # was replaced can never take the tree back.
  #
  # A snapshot is taken at the first batch, every `snapshot_every` seconds after, and when the
  # root finishes, and each one trims the stream back to the one before it. Every key expires
  # `retain` seconds after the last snapshot - a run that dies leaves nothing behind for good.
  #
  # With `heartbeat`, every so many seconds it marks itself alive and takes the cancel requests that
  # came for it, on a thread of its own - from the first batch until the root finishes or it is
  # closed. A request names the run it is for; a run also takes those for the run it took over
  # from (`took_over`), so a cancel sent while a job still waited in the queue reaches whoever
  # takes it up.
  #
  # A write that fails - Redis went away for a moment - is not lost: the next batch goes out as
  # the whole tree, squashed, and readers start over from it
  class StreamOutput
    # The key it writes under
    attr_reader :key #: String

    # @rbs @stream: untyped
    # @rbs @heartbeat: (Integer | Float)?
    # @rbs @snapshot_every: Integer | Float
    # @rbs @retain: Integer | Float
    # @rbs @took_over: String?
    # @rbs @run: String?
    # @rbs @state: State
    # @rbs @snapshot_id: String?
    # @rbs @snapped_at: Float
    # @rbs @beating: Thread?
    # @rbs @stop: Thread::Queue
    # @rbs @broken: bool
    # @rbs @covered: Integer
    # @rbs @replaced: bool
    # @rbs @log: Log?

    # The key of the squashed tree a reader starts from
    #: (String) -> String
    def self.snapshot_key(key) = "#{key}:snapshot"

    # The key that is there while the writer is alive
    #: (String) -> String
    def self.beat_key(key) = "#{key}:beat"

    # The key cancel requests are appended to
    #: (String) -> String
    def self.control_key(key) = "#{key}:control"

    # The key that names the run writing the tree now
    #: (String) -> String
    def self.run_key(key) = "#{key}:run"

    # A key for a new tree. The braces make it a Redis Cluster hash tag, so all five keys of a
    # tree land on the same node
    #: (String) -> String
    def self.key_for(id) = "task_progress:{#{id}}"

    # Writes to `stream` under `key`. `took_over` is the run it takes the tree over from
    #: (untyped, String, ?heartbeat: (Integer | Float)?, ?snapshot_every: Integer | Float, ?retain: Integer | Float, ?took_over: String?) -> void
    def initialize(stream, key, heartbeat: nil, snapshot_every: 2, retain: 86_400, took_over: nil)
      @stream = stream
      @key = key
      @heartbeat = heartbeat
      @snapshot_every = snapshot_every
      @retain = retain
      @took_over = took_over
      @run = nil
      @state = State.new
      @snapshot_id = nil
      @snapped_at = 0.0
      @beating = nil
      @stop = Thread::Queue.new
      @broken = false
      @covered = 0
      @replaced = false
      @log = nil
    end

    # Appends the batch, and takes a snapshot when one is due
    #: (Batch, Log) -> void
    def call(batch, log)
      @log = log
      return if @replaced
      # A batch the last resync already carried
      return if batch.seq <= @covered && !batch.reset?
      batch = resync(log) if @broken
      run = @run ||= claim(batch.log || @key)
      id = @stream.append(@key, Wire.dump(batch))
      @state = State.new if batch.reset?
      batch.events.each { @state.apply(it, at: batch.at) }
      finished = !!@state[[]]&.finished?
      snapshot(id, batch, run) if batch.reset? || finished || now - @snapped_at >= @snapshot_every
      if finished
        finish(run)
      elsif @heartbeat && !@beating && !@stop.closed?
        @beating = Thread.new(log) { beat(it) }
      end
    rescue
      @broken = true
      raise
    end

    # Stops beating, and taking cancel requests - the work is over, one way or another. If the
    # last write failed, the tree goes out whole once more, so readers do not stop short of the end
    #: () -> void
    def close
      if @broken && (log = @log) && !@replaced
        begin
          call(log.squashed, log)
        rescue => e
          log.on_error.call(e, self)
        end
      end
      stop
      @beating&.join
    end

    # Whether a later run has taken the tree over, so this one writes no more
    #: () -> bool
    def replaced? = @replaced

    private

    #: () -> Float
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    #: () -> void
    def stop = @stop.close

    #: (String) -> [String, String]
    def guard(run) = [StreamOutput.run_key(@key), run]

    # The run starts: from now on the tree is this run's to snapshot, trim and beat for
    #: (String) -> String
    def claim(run)
      @stream.set(StreamOutput.run_key(@key), run, expires_in: @retain)
      run
    end

    # The whole tree as one batch, in place of what failed to go out
    #: (Log) -> Batch
    def resync(log)
      @broken = false
      log.squashed.tap { @covered = it.seq }
    end

    #: (String, Batch, String) -> void
    def snapshot(id, batch, run)
      squash = Batch.new(log: batch.log, prev: 0, seq: batch.seq, at: batch.at, events: @state.squash.freeze)
      written = @stream.set(StreamOutput.snapshot_key(@key), JSON.generate({id:, batch: Wire.to_h(squash)}), expires_in: @retain, guard: guard(run))
      return replaced unless written
      # A reader still on its way through the entries since the last snapshot gets to finish them
      @stream.trim(@key, before: @snapshot_id, guard: guard(run)) if @snapshot_id
      [@key, StreamOutput.control_key(@key), StreamOutput.run_key(@key)].each { @stream.expire(it, @retain, guard: guard(run)) }
      @snapshot_id = id
      @snapped_at = now
    end

    #: (String) -> void
    def finish(run)
      stop
      @stream.delete(StreamOutput.beat_key(@key), guard: guard(run))
    end

    #: () -> void
    def replaced
      @replaced = true
      stop
    end

    #: (Log) -> void
    def beat(log)
      root = TaskProgress.handle(log, [])
      every = @heartbeat or return
      run = @run or return
      after = nil #: String?
      until @stop.closed?
        begin
          alive = @stream.set(StreamOutput.beat_key(@key), run, expires_in: [every * 3, 1].max, guard: guard(run))
          next replaced unless alive
          @stream.read(StreamOutput.control_key(@key), after:).each do |id, line|
            after = id
            root.take_cancel_request(line) if for_this_run?(line, run)
          end
        rescue => e
          log.on_error.call(e, self)
        end
        @stop.pop(timeout: every)
      end
    end

    # A request names the run it was sent to - the one its sender saw writing the tree. Ones from
    # before runs were named, and from a parent's control pipe, name none
    #: (String, String) -> bool
    def for_this_run?(line, run)
      named = JSON.parse(line)["run"] if line.start_with?("{")
      named.nil? || named == run || named == @took_over
    rescue JSON::ParserError
      false
    end
  end
end
