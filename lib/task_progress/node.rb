# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # One task, as the tree holds it, see below
  Node = Struct.new(
    :name, #: String
    :total, #: Integer?
    :count, #: Integer
    :percent, #: Integer | Float
    :weight, #: Float
    :expect, #: Integer?
    :indeterminate, #: bool?
    :unit, #: String?
    :cancelable, #: bool?
    :attempt, #: Integer?
    :message, #: String?
    :status, #: Symbol
    :error, #: Hash[Symbol, untyped]?
    :stale, #: bool?
    :opened_at, #: Float
    :started_at, #: Float?
    :finished_at, #: Float?
    :children, #: Array[String]
    :sealed, #: Mount?
    :autofinish #: bool?
  )

  # One task, as the tree holds it - what an output or a renderer reads: its name, status, count
  # and the rest of State::FIELDS. `children` (their ids), `sealed` (the Mount that feeds it) and
  # `autofinish` are the tree's own bookkeeping, and never go over the wire
  class Node
    # Ended by a `done`, `fail` or `cancel` of its own - whatever is still open under it
    #: () -> bool
    def finished? = status == :done || status == :failed || status == :canceled

    # As a `put` carries it: State::FIELDS, without what is at its default
    #: () -> Hash[Symbol, untyped]
    def to_h
      State::FIELDS.to_h { [it, self[it]] }.compact.tap do |h|
        h.delete(:stale) unless stale
        h.delete(:indeterminate) unless indeterminate
        h.delete(:cancelable) unless cancelable
        h.delete(:weight) if weight == 1.0 # rubocop:disable Lint/FloatComparison -- the default, set exactly, never computed
      end
    end

    # A copy whose list of children can change without changing this one
    #: () -> Node
    def deep_dup = dup.tap { it.children = children.dup }
  end
end
