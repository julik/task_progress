# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # One change to one node. `path` leads to the node by its ancestors' ids - `[]` is the root,
  # `["x3k0", "00af"]` a child of the root's child "x3k0". Each id is four random base36
  # characters, unique among its siblings and never the task's name: names repeat, and they
  # may say more than should leave the process
  #
  # The ops:
  #     open   {name, total, weight, expect, indeterminate, unit} - a new node
  #     meta   any of open's keys, and `stale` - attributes changed after the fact
  #     set    a percent, 0..100
  #     add    a delta to the node's count
  #     note   a message
  #     done   nil
  #     fail   an error hash, see Wire.error_to_h
  #     cancel a reason, or nil - the work was called off, and did not fail
  #     prune  nil - drop every descendant of the node
  #     put    a whole node, see Node#to_h - what a squashed log is made of
  #     say    a line to print, which changes nothing in the tree - so a squash drops it, the
  #            way a terminal's scrollback is gone once a program exits
  # @rbs skip
  Event = Data.define(:path, :op, :value)

  # @rbs!
  #   class Event < Data
  #     attr_reader path: path
  #     attr_reader op: Symbol
  #     attr_reader value: untyped
  #     def self.new: (path: path, op: Symbol, ?value: untyped) -> instance
  #     def with: (?path: path, ?op: Symbol, ?value: untyped) -> instance
  #   end

  class Event
    # An event for the node at `path` - its path is frozen, so the event can be shared
    #: (path: path, op: Symbol, ?value: untyped) -> void
    def initialize(path:, op:, value: nil)
      # RBS has no keywords for Data#initialize, which takes them all the same
      super(path: path.frozen? ? path : path.dup.freeze, op:, value:) # steep:ignore
    end
  end

  # Every op there is - see Event
  OPS = %i[open meta set add note done fail cancel prune put say].freeze #: Array[Symbol]
end
