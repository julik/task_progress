# frozen_string_literal: true

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
    STEP_WITHOUT_TOTAL = 64 * 1024

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
    %i[readpartial read_nonblock sysread].each do |name|
      define_method(name) { |*args, **options| super(*args, **options).tap { notify_read } }
    end

    # Reports what was read since the last step
    def flush_progress
      return if @furthest == @reported || @task.finished?
      @task.advance!(@furthest - @reported)
      @reported = @furthest
    end

    private

    def moved_to(pos)
      return if pos <= @furthest
      @furthest = pos
      flush_progress if @furthest - @reported >= @step || (@total && @furthest >= @total)
    end
  end
end
