# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # The tree boiled down to the root's percent and the latest thing said, for a progress
  # column in a database or a single status line. A batch that changes neither is not passed on
  class SummaryOutput
    # @rbs @block: ^(percent: Integer, message: String?) -> void
    # @rbs @percent: Integer

    # Calls the block with `percent:` and `message:` whenever either changes
    #: () { (percent: Integer, message: String?) -> void } -> void
    def initialize(&block)
      @block = block
      @percent = 0
    end

    # Takes one batch, see Log#add_output
    #: (Batch, Log) -> void
    def call(batch, log)
      snapshot = log.snapshot
      message = nil #: String?
      batch.events.each do |event|
        case event.op
        when :note, :say then message = event.value if event.value
        when :done then message = "#{snapshot[event.path]&.name} complete"
        when :fail then message = "#{snapshot[event.path]&.name} failed"
        when :cancel then message = "#{snapshot[event.path]&.name} canceled"
        end
      end
      percent = snapshot.percent
      return if message.nil? && percent == @percent
      @percent = percent
      @block.call(percent:, message:)
    end
  end
end
