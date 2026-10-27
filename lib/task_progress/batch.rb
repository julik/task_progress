# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # The unit of commit, see below
  Batch = Data.define(
    :log, #: String?
    :prev, #: Integer
    :seq, #: Integer
    :at, #: Float
    :events #: Array[Event]
  )

  # The unit of commit: everything one transaction changed, in order. `seq` counts batches,
  # not events, and `prev` names the batch it follows - so a reader that sees a `prev` other
  # than the `seq` it last saw knows it missed something. `prev` 0 means "from the start",
  # which is also how a squashed replay announces itself
  class Batch
    # Whether it starts over from nothing, as a squash does
    #: () -> bool
    def reset? = prev.zero?
  end
end
