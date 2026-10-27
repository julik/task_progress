# frozen_string_literal: true

class TaskProgress
  # An output for one subtree, which it sees as a tree of its own: the branch's node becomes the
  # root, `[*branch, 1, 4]` becomes `[1, 4]`, and batches that do not touch the branch are left
  # out. That is a Mount run backwards - a Mount fed from a Branch grafts the subtree back whole.
  #
  # Since batches get left out, a branch numbers its own: `log` is the log's id with the branch
  # path appended, and its `prev`/`seq` follow on from each other just like the log's do.
  #
  # Pruning an ancestor takes the branch's node away with it. Should a task open on that path
  # again (paths of pruned children do get reused), the branch follows it, and announces the
  # new task with a reset - `prev` 0 - so a reader does not mix it up with the old one
  class Branch
    attr_reader :output, :path, :id

    def self.id(log_id, path) = "#{log_id}/#{path.join(".")}"

    def initialize(output, path, log_id, seq)
      @output = output
      @path = path
      @id = Branch.id(log_id, path)
      @seq = seq
      @gone = false
    end

    def call(batch, log)
      reset = batch.reset?
      events = []
      batch.events.each do |event|
        if event.op == :prune && event.path.length < @path.length && @path[0, event.path.length] == event.path
          @gone = reset = true
          events.clear
        elsif event.path[0, @path.length] == @path
          events << relative(event, batch.at)
        end
      end
      return if events.empty? && !reset
      @seq += 1
      @output.call(Batch.new(log: @id, prev: reset ? 0 : @seq - 1, seq: @seq, at: batch.at, events: events.freeze), log)
    end

    private

    def relative(event, at)
      path = event.path.drop(@path.length).freeze
      return Event.new(path:, op: event.op, value: event.value) unless @gone
      # Only an open or a put can bring the node back. An open would leave a reader that keeps
      # the old root (a Mount does) with its count and status, so it goes out as a fresh put
      @gone = false
      return event.with(path:) unless event.op == :open
      Event.new(path:, op: :put, value: event.value.merge(status: :pending, count: 0, percent: 0, opened_at: at).compact)
    end
  end
end
