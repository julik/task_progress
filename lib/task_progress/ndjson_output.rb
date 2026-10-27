# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # One batch per line, for a Mount at the other end of a pipe. Each line goes out in one
  # write, so a reader never sees a batch half-written unless the writer died writing it -
  # and Wire.each_batch drops that one
  class NDJSONOutput
    # @rbs @io: IO | StringIO

    # Writes to `io`, which it makes sync
    #: (IO | StringIO) -> void
    def initialize(io)
      @io = io
      @io.sync = true
    end

    # Writes the batch as one line
    #: (Batch, Log) -> void
    def call(batch, _log)
      @io.write(Wire.dump(batch) + "\n")
    end
  end
end
