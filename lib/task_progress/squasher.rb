# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # Squashes runs of batches into one. It mirrors the tree they build, so for a run it can
  # send the prunes it saw and then a put for every node the run touched - which lands any
  # reader that had the tree up to the run's `prev` exactly where the run left it, times
  # and all, without replaying the steps in between. What was said is not in the tree, so
  # it goes along after the puts
  class Squasher # :nodoc:
    # @rbs @state: State

    # Starts from an empty tree
    #: () -> void
    def initialize = @state = State.new

    # One batch that lands a reader where the run of batches would have
    #: (Array[Batch]) -> Batch
    def squash(batches)
      prunes = [] #: Array[Event]
      says = [] #: Array[Event]
      touched = {} #: Hash[path, bool]
      first = batches.first or raise ArgumentError, "Nothing to squash"
      prev = first.prev
      batches.each do |batch|
        if batch.reset?
          @state = State.new
          prunes.clear
          says.clear
          touched.clear
          prev = 0
        end
        journal = Journal.new
        begin
          batch.events.each { @state.apply(it, at: batch.at, journal:) }
        rescue ArgumentError
          # A batch that does not fit the tree it knows - it joined late, say - leaves that tree as
          # it was. One alone goes on as it is, for whoever reads it to judge
          @state.rollback(journal)
          raise if batches.length > 1
          return batch
        end
        batch.events.each do |event|
          prunes << event if event.op == :prune
          next says << event if event.op == :say
          # set, add, note, done and fail start every node above theirs
          (0..event.path.length).each { touched[event.path.take(it)] = true }
        end
      end
      return first if batches.length == 1
      last = batches.last or raise ArgumentError, "Nothing to squash"
      puts = @state.each.filter_map { |path, node| Event.new(path:, op: :put, value: node.to_h) if touched[path] }
      # The lines go after the puts, which bring their tasks back - but not for a task pruned
      # since, which nothing after the prune would know
      said = says.select { @state.key?(it.path) }
      Batch.new(log: last.log, prev:, seq: last.seq, at: last.at, events: [*prunes, *puts, *said].freeze)
    end
  end
end
