# frozen_string_literal: true

class TaskProgress
  # Squashes runs of batches into one. It mirrors the tree they build, so for a run it can
  # send the prunes it saw and then a put for every node the run touched - which lands any
  # reader that had the tree up to the run's `prev` exactly where the run left it, times
  # and all, without replaying the steps in between. What was said is not in the tree, so
  # it goes along after the puts
  class Squasher
    def initialize = @state = State.new

    def squash(batches)
      prunes = []
      says = []
      touched = {}
      prev = batches.first.prev
      batches.each do |batch|
        if batch.reset?
          @state = State.new
          prunes.clear
          says.clear
          touched.clear
          prev = 0
        end
        batch.events.each do |event|
          @state.apply(event, at: batch.at)
          prunes << event if event.op == :prune
          next says << event if event.op == :say
          # set, add, note, done and fail start every node above theirs
          (0..event.path.length).each { touched[event.path[0, it]] = true }
        end
      end
      return batches.first if batches.length == 1
      puts = @state.each.filter_map { |path, node| Event.new(path:, op: :put, value: node.to_h) if touched[path] }
      Batch.new(log: batches.last.log, prev:, seq: batches.last.seq, at: batches.last.at, events: [*prunes, *puts, *says].freeze)
    end
  end
end
