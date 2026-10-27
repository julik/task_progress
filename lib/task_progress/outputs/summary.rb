# frozen_string_literal: true

class TaskProgress
  module Outputs
    # The tree boiled down to the root's percent and the latest thing said, for a progress
    # column in a database or a single status line. A batch that changes neither is not passed on
    class Summary
      def initialize(&block)
        @block = block
        @percent = 0
      end

      def call(batch, log)
        snapshot = log.snapshot
        message = nil
        batch.events.each do |event|
          case event.op
          when :note, :say then message = event.value if event.value
          when :done then message = "#{snapshot[event.path]&.name} complete"
          when :fail then message = "#{snapshot[event.path]&.name} failed"
          end
        end
        percent = snapshot.percent
        return if message.nil? && percent == @percent
        @percent = percent
        @block.call(percent:, message:)
      end
    end
  end
end
