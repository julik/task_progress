# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # Two pipes between a Mount and a child process: one the child writes its batches up, one it
  # reads cancel requests from. Starting the child is yours, as is waiting for it, signaling it
  # and making sense of how it exited - this only carries the progress:
  #
  #     pipes = engine.pipes
  #     pid = Process.spawn(pipes.env, "bin/render", **pipes.redirects)
  #     pipes.follow
  #     Process.wait(pid)
  #
  # The child finds both through `env` - TaskProgress.cli does. They are the descriptors' own
  # numbers, so the same `env` does for a forked child, which already has them, and for one
  # started with `exec`, which keeps them through `redirects`. Canceling the mount asks the
  # child to cancel its root, and that is all it does: a child that will not listen is yours to
  # stop
  class Pipes
    # What a child finds the pipes by: `TASK_PROGRESS_FD`, to write batches to, and
    # `TASK_PROGRESS_CONTROL_FD`, to read cancel requests from
    attr_reader :env #: Hash[String, String]
    # The child's ends by their numbers, for `Process.spawn` to keep them open across `exec`
    attr_reader :redirects #: Hash[Integer, IO]

    # @rbs @mount: Mount
    # @rbs @reader: IO
    # @rbs @writer: IO
    # @rbs @control_reader: IO
    # @rbs @control: IO

    # Pipes for the mount - see Mount#pipes, which makes them
    #: (Mount) -> void
    def initialize(mount)
      @mount = mount
      @reader, @writer = IO.pipe
      @control_reader, @control = IO.pipe
      @env = {"TASK_PROGRESS_FD" => @writer.fileno.to_s, "TASK_PROGRESS_CONTROL_FD" => @control_reader.fileno.to_s}.freeze
      @redirects = {@writer.fileno => @writer, @control_reader.fileno => @control_reader}.freeze
      mount.take_control(@control)
    end

    # Reads what the child sends until it closes its end, which it does by exiting, and closes
    # the pipes. Call it once the child has started: it first closes this process's copies of
    # the child's ends, or it would be waiting on itself. A child that went away without
    # finishing its root fails the mount. Interrupted, it cancels the mount - which asks the
    # child to stop - and raises on. Returns the mount's task
    #: () -> TaskProgress
    def follow
      close_child_ends
      @mount.read(@reader)
      task = @mount.task
      task.fail!("Closed its pipe without finishing") unless task.finished?
      task
    rescue Interrupt => e
      @mount.task.cancel!(TaskProgress.interrupted_by(e))
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      @mount.task.fail!(e)
      raise
    ensure
      close
    end

    # Closes every end still open here - for when the child never started. #follow does it too
    #: () -> void
    def close
      close_child_ends
      @reader.close unless @reader.closed?
      @mount.release_control(@control)
    end

    private

    #: () -> void
    def close_child_ends
      @writer.close unless @writer.closed?
      @control_reader.close unless @control_reader.closed?
    end
  end
end
