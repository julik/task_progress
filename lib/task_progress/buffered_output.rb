# frozen_string_literal: true

class TaskProgress
  # Puts a thread between the log and a slow output. The first batch goes through at once,
  # and whatever piles up while the output works (or during `interval` after it) goes out
  # squashed into one - so a database write a few times a second keeps up with any number of
  # workers, and never holds one of them up
  class BufferedOutput
    def initialize(output, interval: 0.25)
      @output = output
      @interval = interval
      @queue = Thread::Queue.new
      @log = nil
      @squasher = Squasher.new
      @thread = Thread.new { run }
    end

    def call(batch, log)
      @log = log
      @queue << batch
    rescue ClosedQueueError
      nil
    end

    # Delivers what is still queued, then stops
    def close
      @queue.close
      @thread.join
    end

    private

    def run
      while (batch = @queue.pop)
        batches = [batch]
        batches << @queue.pop until @queue.empty?
        begin
          @output.call(@squasher.squash(batches), @log)
        rescue => e
          warn("TaskProgress: #{@output.inspect} raised #{e.class}: #{e.message}")
        end
        sleep(@interval) unless @queue.closed?
      end
    end
  end
end
