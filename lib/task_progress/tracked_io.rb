# frozen_string_literal: true
# rbs_inline: enabled

begin
  require "progressive_io"
rescue LoadError
  raise LoadError, "TaskProgress#track_io needs the progressive_io gem - add `gem \"progressive_io\"` to your Gemfile"
end

class TaskProgress
  # A ProgressiveIO that advances a task by how far it has been read. Readers seek (ZipKit reads
  # the end of an archive first), so only the furthest position counts. The task moves in steps,
  # a thousandth of the total by default - a loop of small reads over a big file would otherwise
  # commit a batch per read, and every output and browser would get each of them
  class TrackedIO < ::ProgressiveIO
    STEP_WITHOUT_TOTAL = 64 * 1024 #: Integer
    private_constant :STEP_WITHOUT_TOTAL

    # @rbs @task: TaskProgress
    # @rbs @total: Integer?
    # @rbs @step: Integer
    # @rbs @furthest: Integer
    # @rbs @reported: Integer

    # Advances `task` as `io` is read, in steps of `step` bytes - see TaskProgress#track_io, which makes one
    #: (IO, TaskProgress, ?total: Integer?, ?step: Integer?) -> void
    def initialize(io, task, total: nil, step: nil)
      @task = task
      @total = total
      @step = step || (total ? [total / 1000, 1].max : STEP_WITHOUT_TOTAL)
      @furthest = 0
      @reported = 0
      super(io) { |pos| moved_to(pos) }
    end

    # ProgressiveIO lets these through unreported, and IO.copy_stream reads anything that is not
    # an IO with readpartial
    # Reads the way IO#readpartial does, and reports how far it got
    #: (*untyped, **untyped) -> untyped
    def readpartial(*, **) = super.tap { notify_read }

    # Reads the way IO#read_nonblock does, and reports how far it got
    #: (*untyped, **untyped) -> untyped
    def read_nonblock(*, **) = super.tap { notify_read }

    # Reads the way IO#sysread does, and reports how far it got
    #: (*untyped, **untyped) -> untyped
    def sysread(*, **) = super.tap { notify_read }

    # Reports what was read since the last step
    #: () -> void
    def flush_progress
      return if @furthest == @reported || @task.finished?
      @task.advance!(@furthest - @reported)
      @reported = @furthest
    end

    private

    #: (Integer) -> void
    def moved_to(pos)
      return if pos <= @furthest
      @furthest = pos
      total = @total
      flush_progress if @furthest - @reported >= @step || (total && @furthest >= total)
    end
  end
end
