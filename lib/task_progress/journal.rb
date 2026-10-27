# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # The changes one transaction made, so that it can be undone whole
  class Journal # :nodoc:
    # @rbs @saved: Hash[path, [Node, Integer]?]

    #: () -> void
    def initialize = @saved = {}

    # Remembers the node as it was before the transaction first touched it - nil for one it opened.
    # A shallow copy, and how many children it had: a transaction only ever adds children at the
    # end, or swaps the list for a new one, so that is enough to put the list back - and a parent
    # of a hundred thousand tasks is not copied whole every time one of them moves
    #: (path, Node?) -> void
    def touch(path, node)
      @saved[path] = (node && [node.dup, node.children.length]) unless @saved.key?(path)
    end

    # Every path it touched, opened or removed
    #: () -> Array[path]
    def paths = @saved.keys

    #: (Hash[path, Node]) -> void
    def rollback(nodes)
      @saved.each do |path, saved|
        next nodes.delete(path) unless saved
        node, length = saved
        node.children.slice!(length..)
        nodes[path] = node
      end
    end
  end
end
