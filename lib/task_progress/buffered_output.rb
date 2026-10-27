# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # Puts a thread between the log and a slow output. The first batch goes through at once,
  # and whatever piles up while the output works (or during `interval` after it) goes out
  # squashed into one - so a database write a few times a second keeps up with any number of
  # workers, and never holds one of them up
  class BufferedOutput
    # @rbs @output: output
    # @rbs @interval: Integer | Float
    # @rbs @queue: Thread::Queue[Batch]
    # @rbs @log: Log?
    # @rbs @squasher: Squasher
    # @rbs @thread: Thread

    # For the slow output, sending to it at most every `interval` seconds
    #: (output, ?interval: Integer | Float) -> void
    def initialize(output, interval: 0.25)
      @output = output
      @interval = interval
      @queue = Thread::Queue.new
      @log = nil
      @squasher = Squasher.new
      @thread = Thread.new { run }
    end

    # Takes one batch, to deliver from its own thread
    #: (Batch, Log) -> void
    def call(batch, log)
      @log = log
      @queue << batch
    rescue ClosedQueueError
      nil
    end

    # Delivers what is still queued, then stops
    #: () -> void
    def close
      @queue.close
      @thread.join
    end

    private

    #: () -> void
    def run
      while (batch = @queue.pop)
        batches = [batch]
        while !@queue.empty? && (more = @queue.pop)
          batches << more
        end
        log = @log or next
        begin
          @output.call(@squasher.squash(batches), log)
        rescue => e
          log.on_error.call(e, @output)
        end
        sleep(@interval) unless @queue.closed?
      end
    end
  end
end
