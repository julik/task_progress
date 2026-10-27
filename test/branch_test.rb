require_relative "test_helper"

class BranchTest < Minitest::Test
  include TestHelpers

  def subtree(snapshot, path) = snapshot.each(path).map { |sub, node| [sub.drop(path.length), node.to_h] }

  def test_a_branch_sees_its_subtree_rooted_at_the_top
    root = TaskProgress.new("root", log: ticking_log)
    root.subtask("Elsewhere").update_to(percent: 10)
    upload = root.subtask("Upload", total: 4)
    part = upload.subtask("Part")
    part.advance!(1)

    batches, output = recording
    upload.add_output(output)
    upload.advance!(2)
    root.subtasks.first.update_to(percent: 20) # not in the branch
    upload.subtasks.first.done!

    assert_equal [[[], :put], [[part.path.last], :put]], batches.first.events.map { [it.path, it.op] }
    assert_equal [[[], :add, 2]], batches[1].events.map { [it.path, it.op, it.value] }
    assert_equal [[part.path.last]], batches[2].events.map(&:path)
    assert_equal 3, batches.length, "a batch outside the branch is left out"
    assert_equal subtree(root.log.snapshot, upload.path), subtree(fold_batches(batches), [])
  end

  def test_a_branch_numbers_its_batches_without_gaps
    root = TaskProgress.new("root")
    upload = root.subtask("Upload")
    other = root.subtask("Other")
    batches, output = recording
    upload.add_output(output)
    5.times do |i|
      other.note("other #{i}")
      upload.note("upload #{i}")
    end

    assert batches.first.reset?
    batches.each_cons(2) { |a, b| assert_equal a.seq, b.prev }
    assert_equal ["#{root.log.id}-#{upload.path.last}"], batches.map(&:log).uniq
  end

  def test_a_branch_squashes_the_same_as_it_streams
    root = TaskProgress.new("root", log: ticking_log)
    branch = root.subtask("Branch", expect: 2)
    branch.subtask("A").update_to(percent: 50)
    branch.subtask("B", total: 3).advance!(1)
    batches, output = recording
    branch.add_output(output)

    squashed = root.log.squashed(branch.path)
    assert_equal batches.first.events, squashed.events
    assert_equal batches.first.log, squashed.log
  end

  def test_a_mount_fed_from_a_branch_grafts_it_back_whole
    source = TaskProgress.new("source", log: ticking_log)
    branch = source.subtask("Engine", total: 10)
    branch.subtask("Warm up").done!

    mirror = TaskProgress.new("mirror", log: ticking_log)
    mount = mirror.mount("Engine")
    branch.add_output { |batch, _| assert_equal :applied, mount << batch }
    branch.advance!(4)
    branch.subtask("Render").update_to(percent: 30)

    assert_equal source.log.snapshot.percent(branch.path), mount.task.percent
    assert_equal ["Warm up", "Render"], mount.task.subtasks.map(&:name)
    assert_equal 4, mount.task.count
  end

  def test_pruning_an_ancestor_ends_the_branch
    root = TaskProgress.new("root")
    job = root.subtask("Job")
    step = job.subtask("Step")
    step.advance!(3)
    batches, output = recording
    step.add_output(output)

    root.log.append(TaskProgress::Event.new(path: job.path, op: :prune))
    assert batches.last.reset?
    assert_empty batches.last.events, "nothing is left to show"

    count = batches.length
    job.subtask("Step again").note("Starting")
    assert_equal count, batches.length, "a task opening under the same parent is not ours"
  end

  def test_an_sse_stream_of_a_pruned_branch_ends
    root = TaskProgress.new("root")
    job = root.subtask("Job")
    step = job.subtask("Step")
    reader = Thread.new { [].tap { |frames| TaskProgress::SSE.new(step).each { frames << it } } }
    sleep 0.02
    root.log.append(TaskProgress::Event.new(path: job.path, op: :prune))
    assert reader.join(2), "the stream ended"
  end

  def test_a_branch_output_is_removed_by_what_was_added
    root = TaskProgress.new("root")
    task = root.subtask("Task")
    batches, output = recording
    task.add_output(output)
    task.remove_output(output)
    task.note("unseen")
    assert_equal 1, batches.length
  end

  def test_the_root_is_not_wrapped
    root = TaskProgress.new("root")
    batches, output = recording
    root.add_output(output)
    root.note("hi")
    assert_equal [root.log.id], batches.map(&:log).uniq
    assert_equal root.log.seq, batches.last.seq
  end

  # Any run of changes, pruning included, must fold to the same subtree upstream and downstream
  def test_a_branch_folds_to_its_subtree_whatever_happens
    20.times do |seed|
      rng = Random.new(seed)
      root = TaskProgress.new("root", log: ticking_log)
      live = [root]
      8.times { live << live.sample(random: rng).subtask("t") }
      watched = live.drop(1).sample(random: rng)
      batches, output = recording
      watched.add_output(output, replay: true)

      200.times do
        task = live.sample(random: rng)
        case rng.rand(7)
        when 0, 1 then live << task.subtask("t", total: [nil, rng.rand(1..9)].sample(random: rng))
        when 2 then task.update_to(percent: rng.rand(0..99))
        when 3 then task.advance!(rng.rand(1..3))
        when 4 then task.done!
        when 5 then task.note("n")
        when 6 then rng.rand(4).zero? && root.log.append(TaskProgress::Event.new(path: task.path, op: :prune))
        end
      rescue ArgumentError, TaskProgress::Canceled
        nil
      end

      assert_equal subtree(root.log.snapshot, watched.path), subtree(fold_batches(batches), []), "seed #{seed}"
    end
  end
end
