# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # The changes one transaction made, so that it can be undone whole
  class Journal # :nodoc:
    # @rbs @saved: Hash[path, Node?]

    #: () -> void
    def initialize = @saved = {}

    # Remembers the node as it was before the transaction first touched it - nil for one it opened
    #: (path, Node?) -> void
    def touch(path, node)
      @saved[path] = node&.deep_dup unless @saved.key?(path)
    end

    #: (Hash[path, Node]) -> void
    def rollback(nodes)
      @saved.each { |path, node| node ? nodes[path] = node : nodes.delete(path) }
    end
  end
end
