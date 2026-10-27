# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # Hands each batch, as its JSON-ready Hash, to anything with `publish(event_name, payload)`
  # - a Sossego::Stream, for one. A reader turns it back into a Batch with Wire.from_h, or
  # feeds it to a Mount as it is
  class PublishingOutput
    # @rbs!
    #   interface _Publisher
    #     def publish: (String event_name, Hash[Symbol, untyped] payload) -> void
    #   end

    # @rbs @target: _Publisher
    # @rbs @event_name: String

    # Publishes to `target` - a Sossego stream, or anything with `publish(event_name, payload)`
    #: (_Publisher, ?event_name: String) -> void
    def initialize(target, event_name: "task_progress")
      @target = target
      @event_name = event_name
    end

    # Publishes the batch as a JSON-ready Hash
    #: (Batch, Log) -> void
    def call(batch, _log)
      @target.publish(@event_name, Wire.to_h(batch))
    end
  end
end
