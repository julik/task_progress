# frozen_string_literal: true

class TaskProgress
  # One change to one node. `path` is the node's position in the tree - `[]` is the root,
  # `[3, 1]` the second child of the root's fourth child. Positions, not names: names repeat,
  # and they may say more than should leave the process
  #
  # The ops:
  #   open   {name, total, weight, expect, indeterminate, unit} - a new node
  #   meta   any of open's keys, and `stale` - attributes changed after the fact
  #   set    a percent, 0..100
  #   add    a delta to the node's count
  #   note   a message
  #   done   nil
  #   fail   an error hash, see Wire.error_to_h
  #   prune  nil - drop every descendant of the node
  #   put    a whole node, see State::Node#to_h - what a squashed log is made of
  Event = Data.define(:path, :op, :value) do
    def initialize(path:, op:, value: nil)
      super(path: path.frozen? ? path : path.dup.freeze, op:, value:)
    end
  end

  OPS = %i[open meta set add note done fail prune put].freeze

  # The unit of commit: everything one transaction changed, in order. `seq` counts batches,
  # not events, and `prev` names the batch it follows - so a reader that sees a `prev` other
  # than the `seq` it last saw knows it missed something. `prev` 0 means "from the start",
  # which is also how a squashed replay announces itself
  Batch = Data.define(:log, :prev, :seq, :at, :events) do
    def reset? = prev.zero?
  end
end
