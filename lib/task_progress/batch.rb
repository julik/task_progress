# frozen_string_literal: true

class TaskProgress
  # The unit of commit: everything one transaction changed, in order. `seq` counts batches,
  # not events, and `prev` names the batch it follows - so a reader that sees a `prev` other
  # than the `seq` it last saw knows it missed something. `prev` 0 means "from the start",
  # which is also how a squashed replay announces itself
  Batch = Data.define(:log, :prev, :seq, :at, :events) do
    def reset? = prev.zero?
  end
end
