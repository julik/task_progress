# frozen_string_literal: true

class TaskProgress
  # One task, as the tree holds it. `sealed` holds the task's Mount when one feeds it, and
  # `autofinish` whether it finishes at its total - neither goes over the wire
  Node = Struct.new(*State::FIELDS, :children, :sealed, :autofinish) do
    def finished? = status == :done || status == :failed || status == :canceled

    def to_h
      State::FIELDS.to_h { [it, self[it]] }.compact.tap do |h|
        h.delete(:stale) unless stale
        h.delete(:indeterminate) unless indeterminate
        h.delete(:cancelable) unless cancelable
        h.delete(:weight) if weight == 1.0
      end
    end

    def deep_dup = dup.tap { it.children = children.dup }
  end
end
