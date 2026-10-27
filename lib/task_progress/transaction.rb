# frozen_string_literal: true

class TaskProgress
  # What a block given to Log#transaction adds its events through. Each one is applied to the
  # tree as it comes, and journaled, so the whole transaction can be undone if the block raises
  class Transaction
    attr_reader :events, :journal, :at, :state

    def initialize(state, at, random)
      @state = state
      @at = at
      @random = random
      @events = []
      @journal = Journal.new
    end

    def <<(event)
      @state.apply(event, at: @at, journal: @journal)
      @events << event
      self
    end

    def new_child(path) = @state.new_child(path, @random)
  end
end
