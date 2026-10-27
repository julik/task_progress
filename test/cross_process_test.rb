require_relative "test_helper"
require "rbconfig"
require "tmpdir"

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
    assert_equal :failed, mount.task.status
    assert_equal "Interrupt", mount.task.error[:class]
  ensure
    File.delete(pid_file) if pid_file && File.exist?(pid_file)
  end

  def test_the_child_leaves_no_fd_for_its_own_children
    mount = TaskProgress.new("local").mount("Engine")
    spawn_child(mount, <<~RUBY)
      TaskProgress.cli("child") { |root| root.note(ENV.fetch("TASK_PROGRESS_FD", "gone")) }
    RUBY
    assert_equal "gone", mount.task.message
  end
end
