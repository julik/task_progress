$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "task_progress"
require "stringio"
require "minitest/autorun"

module TestHelpers
  # A log whose clock ticks a second per transaction, so times survive the wire's rounding
  def ticking_log
    t = 1_700_000_000.0
    TaskProgress::Log.new(clock: -> { t += 1.0 })
  end

  def recording
    batches = []
    [batches, ->(batch, _log) { batches << batch }]
  end

  def fold_batches(batches, state = TaskProgress::State.new)
    batches.each do |batch|
      state = TaskProgress::State.new if batch.reset?
      batch.events.each { state.apply(it, at: batch.at) }
    end
    state
  end
end
