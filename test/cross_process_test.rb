require_relative "test_helper"
require "rbconfig"
require "tmpdir"
require "timeout"

# Real children: TaskProgress.cli on their end, Mount#spawn on ours
class CrossProcessTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def spawn_child(mount, script)
    mount.spawn(RbConfig.ruby, "-I", LIB, "-rtask_progress", "-e", script, err: File::NULL)
  end

  def test_a_child_tree_is_mirrored_and_finishes_the_mount
    local = TaskProgress.new("local")
    local.subtask("Prep").done!
    mount = local.mount("Engine")
    status = spawn_child(mount, <<~RUBY)
      TaskProgress.cli("child") do |root|
        root.subtask("Unpack", total: 3) { |t| 3.times { t.tick!(message: "entry \#{it}") } }
        root.subtask("Embed") { |t| t.update_to(percent: 50, message: "half") }
      end
    RUBY

    assert status.success?
    assert_equal :done, mount.task.status
    assert_equal [["Unpack", :done, 3], ["Embed", :done, 0]], mount.task.subtasks.map { [it.name, it.status, it.count] }
    assert_equal "half", mount.task.subtasks.last.message
    assert mount.task.done?, "the child finished its root, so the mount is done"
    refute local.done?, "local itself was never finished"
  end

  def test_a_child_failure_crosses_with_its_error
    mount = TaskProgress.new("local").mount("Engine")
    status = spawn_child(mount, <<~RUBY)
      TaskProgress.cli("child") do |root|
        root.subtask("Doomed") { raise ArgumentError, "bad input" }
      end
    RUBY

    refute status.success?
    doomed = mount.task.subtasks.first
    assert_equal :failed, doomed.status
    assert_equal "ArgumentError", doomed.error[:class]
    assert_equal "bad input", mount.task.error[:message], "the child's root failed with it too"
    refute_empty doomed.error[:backtrace]
  end

  def test_a_child_killed_mid_line_keeps_what_arrived_and_fails_the_mount
    mount = TaskProgress.new("local").mount("Engine")
    status = spawn_child(mount, <<~RUBY)
      root = TaskProgress.cli("child")
      root.subtask("Before").done!
      IO.new(3).tap { it.sync = true }.write('{"log":"x","prev":3,"seq":4,"ops":[[[0],"no')
      Process.kill(:KILL, Process.pid)
    RUBY

    assert status.signaled?
    assert_equal ["Before"], mount.task.subtasks.map(&:name)
    assert_equal :failed, mount.task.status
    assert_match(/exited with 9/, mount.task.error[:message])
  end

  def test_a_child_that_dies_without_finishing_fails_the_mount
    mount = TaskProgress.new("local").mount("Engine")
    spawn_child(mount, 'TaskProgress.cli("child").subtask("Left hanging"); exit!(0)') # exit! skips at_exit
    assert_equal :failed, mount.task.status
    assert_match(/without finishing/, mount.task.error[:message])
  end

  def test_a_child_that_never_finished_its_root_is_finished_at_exit
    mount = TaskProgress.new("local").mount("Engine")
    spawn_child(mount, 'TaskProgress.cli("child").subtask("Left open")')
    assert_equal [:done, :done], [mount.task.status, mount.task.subtasks.first.status]
  end

  def test_canceling_a_task_above_a_mount_cancels_it_and_terminates_the_child
    root = TaskProgress.new("local")
    mount = root.mount("Engine")
    worker = Thread.new do
      spawn_child(mount, <<~RUBY)
        TaskProgress.cli("child") { |r| r.subtask("Forever") { |t| loop { t.note("tick") && sleep(0.02) } } }
      RUBY
    end
    sleep 0.05 until mount.task.subtasks.any?
    root.cancel!("Not needed")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status = worker.value
    assert status.success?, "asked over the control pipe, the child canceled its root and exited by itself"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_equal [:canceled, :canceled, :canceled], [root, mount.task, mount.task.subtasks.first].map(&:status)
  end

  def test_canceling_the_mounts_own_task_terminates_the_child
    root = TaskProgress.new("local")
    mount = root.mount("Engine", cancelable: true)
    worker = Thread.new do
      spawn_child(mount, 'TaskProgress.cli("child") { |r| r.subtask("Forever") { |t| loop { t.note("tick") && sleep(0.02) } } }')
    end
    sleep 0.05 until mount.task.subtasks.any?
    assert_equal :canceled, root.request_cancel(mount.path, "From the browser")
    assert worker.value.success?
    assert_equal [:canceled, :canceled], [mount.task.status, mount.task.subtasks.first.status]
    assert_raises(ArgumentError, "under it is still the Mount's") { mount.task.subtasks.first.note("x") }
    refute mount.task.node.stale, "what the child sent on its way out is not taken for a gap"
  end

  def test_a_child_too_stuck_to_listen_is_terminated_after_the_grace_period
    root = TaskProgress.new("local")
    mount = root.mount("Engine")
    worker = Thread.new do
      mount.spawn(RbConfig.ruby, "-I", LIB, "-rtask_progress", "-e", 'TaskProgress.cli("child") { |r| r.note("in"); sleep }', err: File::NULL, grace: 0.3)
    end
    sleep 0.05 until mount.task.status == :active
    root.cancel!
    assert worker.value.signaled?
  end

  def test_a_cancel_request_reaches_a_task_inside_the_child
    root = TaskProgress.new("local")
    mount = root.mount("Engine")
    worker = Thread.new do
      spawn_child(mount, <<~RUBY)
        TaskProgress.cli("child") do |r|
          r.subtask("Optional", cancelable: true) { |t| loop { t.note("tick") && sleep(0.02) } }
          r.subtask("After") { |t| t.note("carried on") }
        end
      RUBY
    end
    sleep 0.05 until (optional = mount.task.subtasks.first)&.status == :active
    assert optional.cancelable?, "with a control pipe, the child's own cancelable tasks may be offered"
    assert_equal :forwarded, root.request_cancel(optional.path, "Skip it")
    assert worker.value.success?
    assert_equal [["Optional", :canceled, "Skip it"], ["After", :done, "carried on"]], mount.task.subtasks.map { [it.name, it.status, it.message] }
    assert_equal :done, mount.task.status
    assert_equal :moot, root.request_cancel(optional.path), "too late is not an error"
    assert_equal :moot, mount.request_cancel(["anything"]), "nor is a child that has exited"
  end

  def test_a_cancel_request_is_routed_through_nested_mounts
    grandchild = <<~RUBY
      TaskProgress.cli("grandchild") do |r|
        r.subtask("Deep", cancelable: true) { |t| loop { t.note("tick") && sleep(0.02) } }
        r.subtask("After") { |t| t.note("carried on") }
      end
    RUBY
    child = <<~RUBY
      TaskProgress.cli("child") do |r|
        r.mount("Inner").spawn(RbConfig.ruby, "-I", #{LIB.inspect}, "-rtask_progress", "-e", #{grandchild.inspect}, err: File::NULL)
      end
    RUBY
    root = TaskProgress.new("local")
    mount = root.mount("Outer")
    worker = Thread.new { spawn_child(mount, child) }
    deep = nil
    Timeout.timeout(10) { sleep 0.02 until (deep = mount.task.subtasks.first&.subtasks&.first)&.status == :active }
    assert_equal :forwarded, root.request_cancel(deep.path, "Two hops down")
    assert worker.value.success?
    inner = mount.task.subtasks.first
    assert_equal [["Deep", :canceled, "Two hops down"], ["After", :done, "carried on"]], inner.subtasks.map { [it.name, it.status, it.message] }
  end

  def test_a_child_that_finishes_by_itself_is_never_signaled
    mount = TaskProgress.new("local").mount("Engine")
    status = spawn_child(mount, 'TaskProgress.cli("child") { |r| r.cancel!("Changed my mind") }')
    assert status.success?
    assert_equal :canceled, mount.task.status
  end

  def test_interrupting_the_parent_terminates_the_child
    mount = TaskProgress.new("local").mount("Engine")
    pid_file = File.join(Dir.tmpdir, "task_progress_child_#{Process.pid}.pid")
    parent = Thread.new do
      spawn_child(mount, <<~RUBY)
        File.write(#{pid_file.inspect}, Process.pid.to_s)
        TaskProgress.cli("child") { |root| root.subtask("Forever") { |t| loop { t.note("still here") && sleep(0.01) } } }
      RUBY
    rescue Interrupt
      :interrupted
    end
    sleep 0.05 until File.exist?(pid_file) && !File.read(pid_file).empty?
    child = Integer(File.read(pid_file))
    sleep 0.3
    parent.raise(Interrupt)
    assert_equal :interrupted, parent.value
    assert_raises(Errno::ESRCH) { Process.kill(0, child) }
    assert_equal :canceled, mount.task.status, "an interrupt calls the work off"
  ensure
    File.delete(pid_file) if pid_file && File.exist?(pid_file)
  end

  def test_the_child_leaves_no_fd_for_its_own_children
    mount = TaskProgress.new("local").mount("Engine")
    spawn_child(mount, <<~RUBY)
      TaskProgress.cli("child") do |root|
        fds = [3, 4].map { IO.for_fd(it, autoclose: false).close_on_exec? }
        root.note([ENV.fetch("TASK_PROGRESS_FD", "gone"), ENV.fetch("TASK_PROGRESS_CONTROL_FD", "gone"), *fds].join(" "))
      end
    RUBY
    assert_equal "gone gone true true", mount.task.message
  end
end
