# frozen_string_literal: true
# rbs_inline: enabled

require "json"

class TaskProgress
  # Reads a tree a StreamOutput writes: the snapshot first, as one batch with `prev` 0, then
  # every batch after it as it comes. Each read picks up where the last one left off.
  #
  # It hands on what it reads, and judges none of it - Mount does that, see Mount#follow_stream.
  # After a gap, `resync!` makes the next read start over from the latest snapshot
  class StreamReader
    # The key it reads
    attr_reader :key #: String

    # @rbs @stream: untyped
    # @rbs @after: String?
    # @rbs @started: bool

    # Reads `stream` at `key`
    #: (untyped, String) -> void
    def initialize(stream, key)
      @stream = stream
      @key = key
      @after = nil
      @started = false
    end

    # The batches since the last read - starting from the snapshot. With a `timeout`, waits up
    # to that many seconds for one when there are none yet
    #: (?timeout: (Integer | Float)?) -> Array[Batch]
    def read(timeout: nil)
      batches = [] #: Array[Batch]
      unless @started
        @started = true
        if (found = snapshot_entry)
          @after, batch = found
          batches << batch
        end
      end
      @stream.read(@key, after: @after, timeout: (timeout if batches.empty?)).each do |id, line|
        @after = id
        batch = Wire.parse(line)
        batches << batch if batch
      end
      batches
    end

    # The next read starts over, from the latest snapshot
    #: () -> void
    def resync!
      @started = false
      @after = nil
    end

    # The tree as of the latest snapshot, as one batch - or nil when nothing was ever written
    # here, or it has expired
    #: () -> Batch?
    def snapshot = snapshot_entry&.last

    # Whether the writer said lately that it is alive
    #: () -> bool
    def alive? = !@stream.get(StreamOutput.beat_key(@key)).nil?

    private

    #: () -> [String, Batch]?
    def snapshot_entry
      data = JSON.parse(@stream.get(StreamOutput.snapshot_key(@key)) || return)
      batch = Wire.from_h(data["batch"]) if data.is_a?(Hash) && data["id"].is_a?(String)
      [data["id"], batch] if batch
    rescue JSON::ParserError
      nil
    end
  end
end
