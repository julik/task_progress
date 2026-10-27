# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # :nodoc:
  Fold = Data.define(
    :status, #: Symbol
    :count #: Integer
  )

  # Siblings drawn as one row - "✓ 9,812 more done", "· 340 more waiting" - so a task with ten
  # thousand children draws as a handful of rows. See State#rows, which makes them
  class Fold
    # What the row says
    #: () -> String
    def name = "#{count.to_s.gsub(/\B(?=(\d{3})+(?!\d))/, ",")} more #{(status == :done) ? "done" : "waiting"}"
  end
end
