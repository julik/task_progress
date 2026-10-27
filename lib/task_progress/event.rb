# frozen_string_literal: true

class TaskProgress
  # One change to one node. `path` leads to the node by its ancestors' ids - `[]` is the root,
  # `["x3k0", "00af"]` a child of the root's child "x3k0". Each id is four random base36
  # characters, unique among its siblings and never the task's name: names repeat, and they
  # may say more than should leave the process
  #
  # The ops:
  #   open   {name, total, weight, expect, indeterminate, unit} - a new node
  #   meta   any of open's keys, and `stale` - attributes changed after the fact
  #   set    a percent, 0..100
  #   add    a delta to the node's count
  #   note   a message
  #   done   nil
  #   fail   an error hash, see Wire.error_to_h
  #   cancel a reason, or nil - the work was called off, and did not fail
  #   prune  nil - drop every descendant of the node
  #   put    a whole node, see Node#to_h - what a squashed log is made of
  #   say    a line to print, which changes nothing in the tree - so a squash drops it, the
  #          way a terminal's scrollback is gone once a program exits
  Event = Data.define(:path, :op, :value) do
    def initialize(path:, op:, value: nil)
      super(path: path.frozen? ? path : path.dup.freeze, op:, value:)
    end
  end

  OPS = %i[open meta set add note done fail cancel prune put say].freeze
end
