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
  # Pruning an ancestor takes the branch's node away. Usually for good, since a pruned path is
  # never given out again - and the branch then sends one last reset with nothing in it, and
  # falls silent. But a Mount starting over (a remote that restarted, a stream resynced) prunes
  # its subtree and puts the same tasks back in the same batch: the branch's node comes back,
  # and the branch starts over with it.
  #
  # Its first batch always starts from nothing, `prev` 0: one for a node that comes into being
  # after the branch was made carries the node's `open`
  class Branch # :nodoc:
    # The output the branch feeds
    attr_reader :output #: output
    # The branch's task, in the whole tree
    attr_reader :path #: path
    # The log id its batches carry: the log's, with the path appended
    attr_reader :id #: String

    # @rbs @seq: Integer
    # @rbs @gone: bool
    # @rbs @started: bool

    # The log id of the branch at `path`
    #: (String, path) -> String
    def self.id(log_id, path) = [log_id, *path].join("-")

    # For an output, the branch at `path` of the log `log_id`, numbering on from `seq`
    #: (output, path, String, Integer, ?started: bool) -> void
    def initialize(output, path, log_id, seq, started: true)
      @output = output
      @path = path
      @id = Branch.id(log_id, path)
      @seq = seq
      @gone = false
      @started = started
    end

    # Passes on what of the batch is in the branch, moved to its root
    #: (Batch, Log) -> void
    def call(batch, log)
      return if @gone
      reset = batch.reset? || !@started
      pruned = false
      events = [] #: Array[Event]
      batch.events.each do |event|
        if event.op == :prune && event.path.length < @path.length && @path[0, event.path.length] == event.path
          pruned = reset = true
          events.clear
        elsif event.path[0, @path.length] == @path
          # Put back after the prune - the branch starts over from it
          pruned = false if event.path.length == @path.length && (event.op == :put || event.op == :open)
          events << Event.new(path: event.path.drop(@path.length).freeze, op: event.op, value: event.value)
        end
      end
      if pruned
        @gone = true
        events.clear
      end
      return if events.empty? && !reset
      @started = true
      @seq += 1
      @output.call(Batch.new(log: @id, prev: reset ? 0 : @seq - 1, seq: @seq, at: batch.at, events: events.freeze), log)
    end
  end
end
