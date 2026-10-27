# frozen_string_literal: true
# rbs_inline: enabled

require "json"

class TaskProgress
  # Writes a tree to a stream - a MemoryStream, a RedisStream - for readers anywhere to follow
  # with StreamReader. What TaskProgress.handoff and TaskProgress.adopt write through. Under one
  # key it keeps:
  #
  #     key            every batch, one entry each
  #     key:snapshot   the tree squashed into one batch, and the id of the entry it is as of -
  #                    where a reader starts, so the stream before it can be trimmed away
  #     key:beat       there while the writer is alive, and gone a few seconds after it is not
  #     key:control    cancel requests, the other way - see Mount#follow_stream
  #
  # A snapshot is taken at the first batch, every `snapshot_every` seconds after, and when the
  # root finishes, and each one trims the stream back to the one before it. Once the root has
  # finished, all of it expires `retain` seconds later.
  #
  # With `beat`, every so many seconds it marks itself alive and takes the cancel requests that
  # came, on a thread of its own - from the first batch until the root finishes or it is closed
  class StreamOutput
    # The key it writes under
    attr_reader :key #: String

    # @rbs @stream: untyped
    # @rbs @beat: (Integer | Float)?
    # @rbs @snapshot_every: Integer | Float
    # @rbs @retain: Integer | Float
    # @rbs @state: State
    # @rbs @snapshot_id: String?
    # @rbs @snapped_at: Float
    # @rbs @beating: Thread?
    # @rbs @stop: Thread::Queue

    # The key of the squashed tree a reader starts from
    #: (String) -> String
    def self.snapshot_key(key) = "#{key}:snapshot"

    # The key that is there while the writer is alive
    #: (String) -> String
    def self.beat_key(key) = "#{key}:beat"

    # The key cancel requests are appended to
    #: (String) -> String
    def self.control_key(key) = "#{key}:control"

    # A key for a new tree. The braces make it a Redis Cluster hash tag, so all four keys of a
    # tree land on the same node
    #: (String) -> String
    def self.key_for(id) = "task_progress:{#{id}}"

    # Writes to `stream` under `key`
    #: (untyped, String, ?beat: (Integer | Float)?, ?snapshot_every: Integer | Float, ?retain: Integer | Float) -> void
    def initialize(stream, key, beat: nil, snapshot_every: 2, retain: 86_400)
      @stream = stream
      @key = key
      @beat = beat
      @snapshot_every = snapshot_every
      @retain = retain
      @state = State.new
      @snapshot_id = nil
      @snapped_at = 0.0
      @beating = nil
      @stop = Thread::Queue.new
    end

    # Appends the batch, and takes a snapshot when one is due
    #: (Batch, Log) -> void
    def call(batch, log)
      id = @stream.append(@key, Wire.dump(batch))
      @state = State.new if batch.reset?
      batch.events.each { @state.apply(it, at: batch.at) }
      finished = !!@state[[]]&.finished?
      snapshot(id, batch) if batch.reset? || finished || now - @snapped_at >= @snapshot_every
      if finished
        stop
        [@key, StreamOutput.snapshot_key(@key), StreamOutput.control_key(@key)].each { @stream.expire(it, @retain) }
        @stream.delete(StreamOutput.beat_key(@key))
      elsif @beat && !@beating && !@stop.closed?
        @beating = Thread.new(log) { beat(it) }
      end
    end

    # Stops beating, and taking cancel requests - the work is over, one way or another
    #: () -> void
    def close
      stop
      @beating&.join
    end

    private

    #: () -> Float
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    #: () -> void
    def stop = @stop.close

    #: (String, Batch) -> void
    def snapshot(id, batch)
      squash = Batch.new(log: batch.log, prev: 0, seq: batch.seq, at: batch.at, events: @state.squash.freeze)
      @stream.set(StreamOutput.snapshot_key(@key), JSON.generate({id:, batch: Wire.to_h(squash)}), expires_in: @retain)
      # A reader still on its way through the entries since the last snapshot gets to finish them
      @stream.trim(@key, before: @snapshot_id) if @snapshot_id
      @snapshot_id = id
      @snapped_at = now
    end

    #: (Log) -> void
    def beat(log)
      Thread.current.report_on_exception = false
      root = TaskProgress.handle(log, [])
      beat = @beat or return
      after = nil #: String?
      loop do
        @stream.set(StreamOutput.beat_key(@key), "1", expires_in: [beat * 3, 1].max)
        @stream.read(StreamOutput.control_key(@key), after:).each do |id, line|
          after = id
          root.take_cancel_request(line)
        end
        @stop.pop(timeout: beat)
        break if @stop.closed?
      end
    rescue => e
      warn("TaskProgress: #{self.class} stopped beating - #{e.class}: #{e.message}")
    end
  end
end
