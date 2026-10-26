# frozen_string_literal: true

class TaskProgress
  module Outputs
    # One batch per line, for a Mount at the other end of a pipe. Each line goes out in one
    # write, so a reader never sees a batch half-written unless the writer died writing it -
    # and Wire.each_batch drops that one
    class NDJSON
      def initialize(io)
        @io = io
        @io.sync = true
      end

      def call(batch, _log)
        @io.write(Wire.dump(batch) + "\n")
      end
    end
  end
end
