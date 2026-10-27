# frozen_string_literal: true

class TaskProgress
  # The changes one transaction made, so that it can be undone whole
  class Journal
    def initialize = @saved = {}

    def touch(path, node)
      @saved[path] = node&.deep_dup unless @saved.key?(path)
    end

    def rollback(nodes)
      @saved.each { |path, node| node ? nodes[path] = node : nodes.delete(path) }
    end
  end
end
