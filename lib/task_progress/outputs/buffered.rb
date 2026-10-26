# frozen_string_literal: true

class TaskProgress
  module Outputs
    # Puts a thread between the log and a slow output. The first batch goes through at once,
    # and whatever piles up while the output works (or during `interval` after it) goes out
    # squashed into one - so a database write a few times a second keeps up with any number of
    # workers, and never holds one of them up
    class Buffered
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

      # Squashes runs of batches into one. It mirrors the tree they build, so for a run it can
      # send the prunes it saw and then a put for every node the run touched - which lands any
      # reader that had the tree up to the run's `prev` exactly where the run left it, times
      # and all, without replaying the steps in between
      class Squasher
        def initialize = @state = State.new

        def squash(batches)
          prunes = []
          touched = {}
          prev = batches.first.prev
          batches.each do |batch|
            if batch.reset?
              @state = State.new
              prunes.clear
              touched.clear
              prev = 0
            end
            batch.events.each do |event|
              @state.apply(event, at: batch.at)
              prunes << event if event.op == :prune
              # set, add, note, done and fail start every node above theirs
              (0..event.path.length).each { touched[event.path[0, it]] = true }
            end
          end
          return batches.first if batches.length == 1
          puts = @state.each.filter_map { |path, node| Event.new(path:, op: :put, value: node.to_h) if touched[path] }
          Batch.new(log: batches.last.log, prev:, seq: batches.last.seq, at: batches.last.at, events: [*prunes, *puts].freeze)
        end
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
end
