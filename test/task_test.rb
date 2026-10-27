require_relative "test_helper"

# The handle API. Much of it carries the cases of the ProgressTree suite this gem came from
class TaskTest < Minitest::Test
  include TestHelpers

  def setup
    @calls = []
  end

  def summary = ->(percent:, message:) { @calls << {percent:, message:} }

  def test_a_root_starts_pending_and_empty
    root = TaskProgress.new("Root")
    assert_equal "Root", root.name
    assert_nil root.parent
    assert_empty root.subtasks
    assert_equal :pending, root.status
    assert_equal 0, root.percent
    refute root.done?
  end

  def test_a_child_id_that_hits_a_sibling_is_drawn_again
    draws = [5, 5, 36**4 - 1]
    root = TaskProgress.new("Root", log: TaskProgress::Log.new(random: Object.new.tap { |r| r.define_singleton_method(:rand) { |_| draws.shift } }))
    assert_equal [["0005"], ["zzzz"]], [root.subtask("A").path, root.subtask("B").path]
  end

  def test_subtasks_know_their_parent_and_path
    root = TaskProgress.new("Root")
    a, b = root.subtask("A"), root.subtask("B")
    a1 = a.subtask("A1")
    assert_equal [1, 1, 2], [a.path.length, b.path.length, a1.path.length]
    assert_equal a.path, a1.path[0, 1]
    assert_equal [a.path, b.path], root.subtasks.map(&:path), "in the order they opened"
    assert_equal root, a.parent
    assert_equal a, a1.parent
    assert_equal root, a1.root
    assert_equal [a, b], root.subtasks
  end

  def test_update_to_moves_the_percent_and_reports
    root = TaskProgress.new("Task", &summary)
    root.update_to(percent: 50, message: "Halfway done")
    assert_equal 50, root.percent
    assert_equal :active, root.status
    assert_equal [{percent: 50, message: "Halfway done"}], @calls
  end

  def test_update_to_100_finishes_the_task
    root = TaskProgress.new("Task", &summary)
    root.update_to(percent: 100, message: "Custom message")
    assert root.done?
    assert_equal :done, root.status
    assert_equal({percent: 100, message: "Task complete"}, @calls.last)
  end

  def test_percent_must_be_in_range
    task = TaskProgress.new("Task")
    assert_raises(ArgumentError) { task.update_to(percent: 150) }
    assert_raises(ArgumentError) { task.update_to(percent: -10) }
    assert_equal :pending, task.status, "a refused update changes nothing"
  end

  def test_a_fractional_percent_is_kept
    task = TaskProgress.new("Task")
    task.update_to(percent: 50.5)
    assert_in_delta 0.505, task.fraction
    assert_equal 51, task.percent
  end

  def test_a_finished_task_refuses_updates_but_finishing_again_is_a_no_op
    task = TaskProgress.new("Task", &summary)
    task.done!
    assert_raises(ArgumentError) { task.update_to(percent: 50) }
    assert_raises(ArgumentError) { task.advance! }
    assert_raises(ArgumentError) { task.note("late") }
    task.done!
    task.fail!("too late")
    assert_equal :done, task.status
    assert_equal 1, @calls.length
  end

  def test_a_failed_task_stays_failed
    task = TaskProgress.new("Task")
    task.fail!
    task.done!
    assert_equal :failed, task.status
    assert_equal "Task failed", task.error[:message]
    assert_raises(ArgumentError) { task.update_to(percent: 50) }
  end

  def test_fail_carries_the_error_its_causes_and_extras
    task = TaskProgress.new("Task")
    begin
      begin
        raise IOError, "inner"
      rescue IOError
        raise ArgumentError, "outer"
      end
    rescue => e
      task.fail!(e, input: true)
    end
    assert_equal "ArgumentError", task.error[:class]
    assert_equal "outer", task.error[:message]
    assert_equal "IOError", task.error.dig(:cause, :class)
    assert_equal true, task.error[:input]
    assert_equal e.backtrace, task.error[:backtrace]
  end

  def test_done_finishes_what_is_still_open_under_it
    batches, output = recording
    root = TaskProgress.new("Root", outputs: [output])
    child = root.subtask("Child")
    grandchild = child.subtask("Grandchild")
    grandchild.note("started")
    finished = root.subtask("Finished").done!
    failed = root.subtask("Failed").fail!("nope")
    root.done!

    assert_equal [[grandchild.path, :done], [child.path, :done], [[], :done]], batches.last.events.map { [it.path, it.op] },
      "each with a done of its own, deepest first, in one batch"
    assert_equal [:done, :done, :done, :failed], [child, grandchild, finished, failed].map(&:status)
    assert root.done?, "a failed child does not hold back a parent that finished regardless"
    assert_equal 100, root.percent
  end

  def test_done_leaves_a_mounted_subtree_to_its_mount
    root = TaskProgress.new("Root")
    mount = root.mount("Remote")
    remote = TaskProgress.new("remote", outputs: [->(batch, _) { mount << batch }])
    remote.subtask("Remote work")
    root.done!
    assert_equal :pending, mount.task.status
    assert_equal :pending, mount.task.subtasks.first.status
    refute root.done?, "the remote is not through yet"
    remote.done!
    assert root.done?
  end

  def test_a_counted_task_finishes_at_its_total
    root = TaskProgress.new("Root")
    rows = root.subtask("Rows", total: 2)
    2.times { rows.tick! }
    assert rows.done?
    rows.tick! # more work than the total said
    assert_equal 2, rows.count
    guess = root.subtask("Guess", total: 2, autofinish: false)
    3.times { guess.tick! }
    refute guess.finished?
  end

  def test_progress_is_the_weighted_mean_of_the_children
    root = TaskProgress.new("Root")
    a, b = root.subtask("A"), root.subtask("B")
    assert_equal 0, root.percent
    a.update_to(percent: 50)
    assert_equal 25, root.percent
    b.update_to(percent: 100)
    assert_equal 75, root.percent
    a.done!
    assert_equal 99, root.percent, "children all through do not finish their parent"
    refute root.done?
    root.done!
    assert_equal 100, root.percent
    assert root.done?
  end

  def test_weights
    root = TaskProgress.new("Root")
    light, heavy = root.subtask("light"), root.subtask("heavy", weight: 3)
    heavy.done!
    assert_equal 75, root.percent
    light.update_to(percent: 50)
    assert_equal 88, root.percent
  end

  def test_expected_subtasks_hold_the_denominator
    root = TaskProgress.new("Root", expect: 2)
    root.subtask("1").update_to(percent: 50)
    assert_equal 25, root.percent
    root.subtask("2").update_to(percent: 100)
    assert_equal 75, root.percent
    root.subtask("3").update_to(percent: 75)
    assert_equal 75, root.percent, "past the expected count the denominator grows"
    root.subtask("4").update_to(percent: 25)
    assert_equal 63, root.percent
  end

  def test_an_expected_subtask_not_yet_made_keeps_the_parent_from_done
    root = TaskProgress.new("Root", expect: 2)
    root.subtask("only").done!
    assert_equal 50, root.percent
    refute root.done?
  end

  def test_the_complex_tree_from_the_original_suite
    root = TaskProgress.new("Fact Extraction", &summary)
    email, llm, memory = root.subtask("Email Analysis"), root.subtask("LLM Processing"), root.subtask("Memory Saving")
    loading, parsing = email.subtask("Email Loading"), email.subtask("Email Parsing")

    loading.update_to(percent: 25, message: "Loading emails...")
    assert_equal 4, root.percent
    loading.update_to(percent: 100, message: "Emails loaded")
    parsing.update_to(percent: 50, message: "Parsing emails...")
    assert_equal 25, root.percent
    parsing.done!
    assert_equal 33, root.percent
    llm.update_to(percent: 75)
    assert_equal 58, root.percent
    memory.update_to(percent: 50)
    assert_equal 75, root.percent
    llm.done!
    memory.done!
    assert_equal 99, root.percent, "Email Analysis was never finished itself"
    email.done!
    root.done!
    assert_equal 100, root.percent
    assert_equal({percent: 100, message: "Fact Extraction complete"}, @calls.last)
  end

  def test_a_tree_never_rounds_up_to_100_with_work_still_running
    root = TaskProgress.new("R")
    root.subtask("A").done!
    b = root.subtask("B")
    b.update_to(percent: 99)
    assert_equal 99, root.percent, "(100 + 99) / 2 is 99.5, which must not read as done"
    refute root.done?
  end

  def test_counted_tasks
    root = TaskProgress.new("R")
    rows = root.subtask("Rows", total: 4, autofinish: false) # the total is a guess
    rows.tick!
    rows.advance!(2, message: "three in")
    assert_equal 75, rows.percent
    assert_equal 3, rows.count
    assert_equal "three in", rows.message
    rows.advance!(5)
    assert_equal 99, rows.percent, "a count past its total is still not done"
    rows.total = 20
    assert_equal 40, rows.percent
    rows.done!
    assert_equal 99, root.percent
    root.done!
    assert_equal 100, root.percent
  end

  def test_indeterminate_tasks_count_for_nothing_until_done
    root = TaskProgress.new("R")
    waiting, other = root.subtask("Waiting", indeterminate: true), root.subtask("Other")
    other.done!
    waiting.note("still waiting")
    assert_equal 50, root.percent
    waiting.done!
    root.done!
    assert root.done?
  end

  def test_the_block_form_finishes_or_fails_the_task
    root = TaskProgress.new("Root")
    assert_equal :ok, root.subtask("Fine") { |t| t.update_to(percent: 50) && :ok }
    assert_equal :done, root.subtasks.first.status

    assert_raises(RuntimeError) { root.subtask("Broken") { raise "Something went wrong" } }
    broken = root.subtasks.last
    assert_equal :failed, broken.status
    assert_equal "Something went wrong", broken.error[:message]
  end

  def test_the_block_form_cancels_on_interrupt
    root = TaskProgress.new("Root")
    assert_raises(Interrupt) { root.subtask("Interrupted") { raise Interrupt } }
    assert_equal :canceled, root.subtasks.first.status
    assert_raises(Interrupt) { root.subtask("Stopped") { raise Interrupt, "Cancelled from the bench" } }
    assert_equal "Cancelled from the bench", root.subtasks.last.message
  end

  def test_cancel_calls_off_the_task_and_everything_open_under_it
    batches, output = recording
    root = TaskProgress.new("Root", outputs: [output])
    job = root.subtask("Job")
    started = job.subtask("Started")
    started.note("going")
    never = job.subtask("Never started")
    finished = job.subtask("Finished").done!
    job.cancel!("Not needed after all")

    assert_equal [[never.path, :cancel], [started.path, :cancel], [job.path, :cancel]], batches.last.events.map { [it.path, it.op] }
    assert_equal [:canceled, :canceled, :canceled, :done], [job, started, never, finished].map(&:status)
    assert_nil never.node.started_at, "calling off what never began does not begin it"
    assert_equal "Not needed after all", job.message
    assert job.finished?
    refute job.done?
    job.cancel!
    job.done!
    assert_equal :canceled, job.status, "ending an ended task does nothing"
    root.done!
    assert root.done?, "a canceled child does not hold back a parent that finished regardless"
  end

  def test_on_cancel_lets_blocked_work_be_unblocked
    root = TaskProgress.new("Root")
    fetch = root.subtask("Fetch", cancelable: true)
    gate = Queue.new
    fetch.on_cancel { |reason| gate << reason }
    worker = Thread.new { fetch.run { gate.pop } } # stuck, and never touches its task
    sleep 0.02
    root.cancel!("Not needed")
    assert_equal "Not needed", worker.value, "the callback unblocked it, with the reason"
    assert_equal :canceled, fetch.status

    late = []
    fetch.on_cancel { late << it }
    assert_equal ["Not needed"], late, "registered after the cancel, it is called at once"
  end

  def test_work_unblocked_by_on_cancel_ends_the_task_quietly
    root = TaskProgress.new("Root")
    reader, writer = IO.pipe
    fetch = root.subtask("Fetch", cancelable: true)
    worker = Thread.new do
      root.run do
        fetch.run { |t| t.on_cancel { reader.close } && reader.read }
        root.subtask("After").done!
      end
    end
    sleep 0.05
    fetch.cancel!
    worker.join
    assert_equal [:canceled, :done], [fetch.status, root.status], "the IOError from the closed pipe is the cancel working"
    writer.close
  end

  def test_on_cancel_is_dropped_when_the_task_ends_otherwise
    root = TaskProgress.new("Root")
    task = root.subtask("Task")
    calls = []
    task.on_cancel { calls << it }
    task.done!
    root.cancel!
    task.on_cancel { calls << it }
    assert_empty calls
    assert_empty root.log.instance_variable_get(:@on_cancel)
  end

  def test_a_raising_on_cancel_does_not_stop_the_others
    errors = []
    root = TaskProgress.new("Root")
    root.log.on_output_error = ->(e, _) { errors << e.message }
    task = root.subtask("Task")
    called = []
    task.on_cancel { raise "oops" }
    task.on_cancel { called << :second }
    task.cancel!
    assert_equal [:second], called
    assert_equal ["oops"], errors
  end

  def test_request_cancel_decides_in_one_go
    root = TaskProgress.new("Root")
    open = root.subtask("Open", cancelable: true)
    plain = root.subtask("Plain")
    finished = root.subtask("Finished", cancelable: true).done!
    assert_equal :refused, root.request_cancel(plain.path)
    assert_equal :moot, root.request_cancel(finished.path)
    assert_equal :moot, root.request_cancel(["nope"])
    assert_equal :canceled, root.request_cancel(open.path.join("-"), "Asked")
    assert_equal :moot, root.request_cancel(open.path), "a second time is moot"
    assert_equal ["Asked", :pending], [open.message, plain.status]
  end

  def test_request_cancel_racing_a_finish_is_moot_or_canceled_never_both
    100.times do
      root = TaskProgress.new("Root")
      task = root.subtask("Task", cancelable: true)
      finisher = Thread.new { task.done! }
      outcome = root.request_cancel(task.path)
      finisher.join
      assert_includes [[:canceled, :canceled], [:moot, :done]], [outcome, task.status]
    end
  end

  def test_a_task_says_whether_it_may_be_called_off
    root = TaskProgress.new("Root")
    rows = root.subtask("Rows", cancelable: true)
    plain = root.subtask("Plain")
    assert rows.cancelable?
    refute plain.cancelable?
    assert_equal true, root.log.squashed.events.find { it.path == rows.path }.value[:cancelable], "it goes on the wire"
    refute root.log.squashed.events.find { it.path == plain.path }.value.key?(:cancelable)
    assert_equal rows, root.find(rows.path.join("-"))
    assert_equal rows, root.find(rows.path)
    assert_nil root.find("nope")
    rows.cancel!
    refute rows.cancelable?, "not once it has ended"
  end

  def test_a_canceled_task_stops_whoever_works_on_it
    root = TaskProgress.new("Root")
    reached = 0
    worker = Thread.new do
      root.subtask("Rows", total: 1000) do |rows|
        1000.times { sleep 0.001; rows.tick! && reached += 1 }
      end
      :carried_on
    end
    sleep 0.05
    root.subtasks.first.cancel!
    assert_equal :carried_on, worker.value, "run takes its own task being called off as the end of its work"
    assert_operator reached, :<, 1000
    assert_raises(TaskProgress::Canceled) { root.subtasks.first.tick! }
  end

  def test_failing_cancels_what_is_still_open_under_it
    root = TaskProgress.new("Root")
    pending = root.subtask("Pending")
    assert_raises(RuntimeError) { root.run { raise "boom" } }
    assert_equal [:failed, :canceled], [root.status, pending.status]
  end

  def test_nested_failures_fail_each_level
    root = TaskProgress.new("Root")
    assert_raises(RuntimeError) do
      root.subtask("Parent") do |parent|
        parent.subtask("Child") { raise "Child error" }
      end
    end
    parent = root.subtasks.first
    assert_equal :failed, parent.status
    assert_equal :failed, parent.subtasks.first.status
  end

  def test_messages_reach_the_tree_as_valid_utf8
    received = []
    task = TaskProgress.new("root") { |percent:, message:| received << message }
    task.update_to(percent: 10, message: "Reading Alice’s.xhtml".b)
    task.update_to(percent: 20, message: "Broken \xE2 byte".b)
    assert_equal ["Reading Alice’s.xhtml", "Broken � byte"], received
  end

  def test_a_transaction_commits_as_one_batch
    batches, output = recording
    root = TaskProgress.new("Root", outputs: [output])
    a, b = root.subtask("A"), root.subtask("B")
    before = batches.length
    root.transaction do
      a.done!
      b.update_to(percent: 50, message: "together")
      root.subtask("C")
    end
    assert_equal before + 1, batches.length
    assert_equal %i[done note set open], batches.last.events.map(&:op)
  end

  def test_a_transaction_that_raises_leaves_nothing_behind
    batches, output = recording
    root = TaskProgress.new("Root", outputs: [output])
    a = root.subtask("A")
    seq = root.log.seq
    assert_raises(RuntimeError) do
      root.transaction do
        a.update_to(percent: 70)
        root.subtask("Ghost")
        raise "no"
      end
    end
    assert_equal seq, root.log.seq
    assert_equal 0, a.percent
    assert_equal [a], root.subtasks
    assert_equal seq, batches.last.seq
  end

  def test_a_refused_change_inside_a_transaction_rolls_back_the_rest
    root = TaskProgress.new("Root")
    a, b = root.subtask("A"), root.subtask("B")
    b.done!
    assert_raises(ArgumentError) do
      root.transaction do
        a.update_to(percent: 70)
        b.update_to(percent: 10)
      end
    end
    assert_equal 0, a.percent
  end

  def test_concurrent_updates_lose_and_duplicate_nothing
    batches, output = recording
    root = TaskProgress.new("Root", outputs: [output])
    workers = 10
    per_worker = 50
    groups = workers.times.map { root.subtask("worker-#{it}", total: per_worker) }
    groups.each_with_index.map do |group, w|
      Thread.new do
        per_worker.times { group.tick!(message: "w#{w} step #{it}") }
        group.done!
      end
    end.each(&:join)

    assert_equal 99, root.percent
    root.done!
    assert root.done?
    assert_equal (1..root.log.seq).to_a, batches.map(&:seq)
    assert(batches.each_cons(2).all? { |a, b| b.prev == a.seq })
    notes = batches.flat_map(&:events).select { it.op == :note }.map(&:value)
    assert_equal workers * per_worker, notes.uniq.length
    assert_equal workers * per_worker, notes.length
  end

  def test_concurrent_block_failure_still_fails_its_task
    root = TaskProgress.new("Root")
    busy = Thread.new { root.subtask("busy", total: 100) { |t| 100.times { t.tick! } } }
    assert_raises(RuntimeError) { root.subtask("boom") { raise "kaboom" } }
    busy.join
    assert_equal :failed, root.subtasks.find { it.name == "boom" }.status
    assert_equal :done, root.subtasks.find { it.name == "busy" }.status
  end

  def test_interleaved_fibers
    messages = []
    root = TaskProgress.new("R") { |percent:, message:| messages << message if message }
    fibers = 3.times.map do |n|
      task = root.subtask("f#{n}")
      Fiber.new do
        3.times do |i|
          task.update_to(percent: i * 30, message: "f#{n}.#{i}")
          Fiber.yield
        end
        task.done!
      end
    end
    fibers.each(&:resume) while fibers.any?(&:alive?)
    assert(root.subtasks.all?(&:done?))
    assert_equal %w[f0.0 f1.0 f2.0], messages.first(3)
    assert_equal 12, messages.length
  end

  def test_null_is_silent
    out, err = capture_io { TaskProgress.null.subtask("a") { it.update_to(percent: 50, message: "half") } }
    assert_empty out
    assert_empty err
  end

  def test_human_bytes
    assert_equal "0 bytes", TaskProgress.human_bytes(0)
    assert_equal "1023 bytes", TaskProgress.human_bytes(1023)
    assert_equal "142 KB", TaskProgress.human_bytes(142 * 1024)
    assert_equal "2.9 MB", TaskProgress.human_bytes((2.9 * 1024**2).to_i)
    assert_equal "1.5 TB", TaskProgress.human_bytes(1.5 * 1024**4)
  end
end
