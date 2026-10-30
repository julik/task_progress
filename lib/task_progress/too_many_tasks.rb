# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # What a Mount fails with when its remote opens more tasks than `max_tasks` allows. A remote
  # that does is taken to have gone wrong - or rogue - and is asked to cancel
  class TooManyTasks < StandardError
  end
end
