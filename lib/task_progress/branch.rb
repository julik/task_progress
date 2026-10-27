# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # An output for one subtree, which it sees as a tree of its own: the branch's node becomes the
  # root, `[*branch, "x3k0"]` becomes `["x3k0"]`, and batches that do not touch the branch are left
  # out. That is a Mount run backwards - a Mount fed from a Branch grafts the subtree back whole.
  #
  # Since batches get left out, a branch numbers its own: `log` is the log's id with the branch
  # path appended, and its `prev`/`seq` follow on from each other just like the log's do.
  #
  # Pruning an ancestor takes the branch's node away for good, since a pruned path is never
  # given out again. The branch then sends one last reset with nothing in it, and falls silent
  class Branch
    # The output the branch feeds
    attr_reader :output #: output
    # The branch's task, in the whole tree
    attr_reader :path #: path
    # The log id its batches carry: the log's, with the path appended
    attr_reader :id #: String

    # @rbs @seq: Integer
    # @rbs @gone: bool

    # The log id of the branch at `path`
    #: (String, path) -> String
    def self.id(log_id, path) = [log_id, *path].join("-")

    # For an output, the branch at `path` of the log `log_id`, numbering on from `seq`
    #: (output, path, String, Integer) -> void
    def initialize(output, path, log_id, seq)
      @output = output
      @path = path
      @id = Branch.id(log_id, path)
      @seq = seq
      @gone = false
    end

    # Passes on what of the batch is in the branch, moved to its root
    #: (Batch, Log) -> void
    def call(batch, log)
      return if @gone
      reset = batch.reset?
      events = [] #: Array[Event]
      batch.events.each do |event|
        if event.op == :prune && event.path.length < @path.length && @path[0, event.path.length] == event.path
          @gone = reset = true
          events.clear
          break
        elsif event.path[0, @path.length] == @path
          events << Event.new(path: event.path.drop(@path.length).freeze, op: event.op, value: event.value)
        end
      end
      return if events.empty? && !reset
      @seq += 1
      @output.call(Batch.new(log: @id, prev: reset ? 0 : @seq - 1, seq: @seq, at: batch.at, events: events.freeze), log)
    end
  end
end
