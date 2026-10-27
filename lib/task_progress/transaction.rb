# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # What a block given to Log#transaction adds its events through. Each one is applied to the
  # tree as it comes, and journaled, so the whole transaction can be undone if the block raises
  class Transaction # :nodoc:
    # What it has added so far, in order
    attr_reader :events #: Array[Event]
    # What it changed, to undo it by
    attr_reader :journal #: Journal
    # The time it opened - every event in it happens then
    attr_reader :at #: Float
    # The tree as the transaction has it so far
    attr_reader :state #: State

    # @rbs @random: Random

    # For changing `state` at `at`, drawing task ids from `random` - see Log#transaction, which opens one
    #: (State, Float, Random) -> void
    def initialize(state, at, random)
      @state = state
      @at = at
      @random = random
      @events = []
      @journal = Journal.new
    end

    # Applies the event, and adds it to the batch
    #: (Event) -> self
    def <<(event)
      @state.apply(event, at: @at, journal: @journal)
      @events << event
      self
    end

    # A path for a new child of `path` - see State#new_child
    #: (path) -> path
    def new_child(path) = @state.new_child(path, @random)
  end
end
