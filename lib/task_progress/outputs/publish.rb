# frozen_string_literal: true

class TaskProgress
  module Outputs
    # Hands each batch, as its JSON-ready Hash, to anything with `publish(event_name, payload)`
    # - a Sossego::Stream, for one. A reader turns it back into a Batch with Wire.from_h, or
    # feeds it to a Mount as it is
    class Publish
      def initialize(target, event_name: "task_progress")
        @target = target
        @event_name = event_name
      end

      def call(batch, _log)
        @target.publish(@event_name, Wire.to_h(batch))
      end
    end
  end
end
