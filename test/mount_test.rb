require_relative "test_helper"

class MountTest < Minitest::Test
  include TestHelpers

  def remote(name = "remote")
    batches, output = recording
    [TaskProgress.new(name, outputs: [output], log: ticking_log), batches]
  end

  def test_a_remote_tree_lands_under_the_mount_by_prefixing
    local = TaskProgress.new("local")
    local.subtask("Prep").done!
    mount = local.mount("Engine", weight: 3)
    child, batches = remote
    a = child.subtask("A", total: 2)
    a.tick!(message: "one")
    batches.each { assert_equal :applied, mount << it }

    assert_equal [1], mount.path
    engine = mount.task
    assert_equal "Engine", engine.name, "the mount keeps the parent's name"
    assert_equal 3.0, engine.node.weight, "...and its weight"
    remote_a = engine.subtasks.first
    assert_equal [1, 0], remote_a.path
    assert_equal ["A", 1, 2, "one"], [remote_a.name, remote_a.count, remote_a.total, remote_a.message]
    assert_equal child.percent, engine.percent
  end

  def test_the_mounted_subtree_mirrors_the_remote_one_exactly
    local = TaskProgress.new("local")
    mount = local.mount("Engine")
    child, batches = remote
    child.subtask("A") { |a| a.subtask("A1", total: 3) { |a1| 3.times { a1.tick! } } }
    b = child.subtask("B", weight: 2)
    b.update_to(percent: 40, message: "forty")
    batches.each { mount << it }

    mirrored = local.log.snapshot.each(mount.path).map { |path, node| [path.drop(mount.path.length), node.to_h.except(:name, :weight, :opened_at, :started_at, :finished_at)] }
    original = child.log.snapshot.each.map { |path, node| [path, node.to_h.except(:name, :weight, :opened_at, :started_at, :finished_at)] }
    assert_equal original, mirrored
  end

  def test_the_remote_root_finishing_finishes_the_mount
    local = TaskProgress.new("local")
    mount = local.mount("Engine")
    child, batches = remote
    child.fail!(ArgumentError.new("bad input"), input: true)
    batches.each { mount << it }
    assert_equal :failed, mount.task.status
    assert_equal "bad input", mount.task.error[:message]
    assert_equal true, mount.task.error[:input]
  end

  def test_only_the_mount_writes_under_the_mount
    local = TaskProgress.new("local")
    mount = local.mount("Engine")
    assert_raises(ArgumentError) { mount.task.subtask("sneaky") }
    assert_raises(ArgumentError) { mount.task.update_to(percent: 50) }
    child, batches = remote
    child.subtask("A")
    batches.each { mount << it }
    assert_raises(ArgumentError) { mount.task.subtasks.first.done! }
    mount.done!
    assert_equal :done, mount.task.status
  end

  def test_a_gap_marks_the_subtree_stale_until_a_reset
    local = TaskProgress.new("local")
    mount = local.mount("Engine")
    child, batches = remote
    a = child.subtask("A")
    a.update_to(percent: 10)
    a.update_to(percent: 20)
    a.update_to(percent: 30)

    assert_equal :applied, mount << batches[0]
    assert_equal :gap, mount << batches[2]
    assert mount.stale?
    assert mount.task.node.stale, "readers see it too"
    assert_equal :gap, mount << batches[3], "nothing applies until a reset"

    assert_equal :applied, mount << child.log.squashed
    refute mount.stale?
    refute mount.task.node.stale
    assert_equal 30, mount.task.subtasks.first.percent
  end

  def test_a_remote_trees_times_move_onto_our_clock
    remote_time = 1_000.0
    child = TaskProgress.new("child", log: TaskProgress::Log.new(clock: -> { remote_time }))
    a = child.subtask("A")
    remote_time = 1_010.0
    a.update_to(percent: 5)
    remote_time = 1_030.0 # A has run 20 seconds by the remote's clock

    local_time = 5_000.0
    local = TaskProgress.new("local", log: TaskProgress::Log.new(clock: -> { local_time }))
    mount = local.mount("Engine")
    mount << child.log.squashed
    node = mount.task.subtasks.first.node
    assert_in_delta 4_980.0, node.started_at, 0.001, "still 20 seconds before now, by our clock"
    assert_in_delta 4_970.0, node.opened_at, 0.001

    local_time = 5_005.0
    remote_time = 1_035.0
    batches, output = recording
    child.log.subscribe(output, replay: false)
    a.done!
    mount << batches.last
    assert_in_delta 25.0, mount.task.subtasks.first.node.then { it.finished_at - it.started_at }, 0.001
  end

  def test_a_reset_with_a_path_too_deep_is_rejected_not_half_applied
    local = TaskProgress.new("local")
    deep = (TaskProgress::Wire::MAX_DEPTH - 2).times.reduce(local) { |t, i| t.subtask("d#{i}") }
    mount = deep.mount("Engine")
    child, = remote
    child.subtask("fits")
    assert_equal :applied, mount << child.log.squashed
    child.subtasks.first.subtask("one level too many")
    assert_equal :rejected, mount << child.log.squashed
    assert_equal ["fits"], mount.task.subtasks.map(&:name), "the subtree was not pruned away"
  end

  def test_a_batch_already_applied_is_a_duplicate_not_a_gap
    local = TaskProgress.new("local")
    mount = local.mount("Engine")
    child, batches = remote
    child.subtask("A").update_to(percent: 40)
    batches.each { mount << it }
    seq = local.log.seq
    assert_equal :duplicate, mount << batches[1]
    assert_equal :duplicate, mount << batches.last
    refute mount.stale?
    assert_equal seq, local.log.seq, "nothing committed for it"
  end

  def test_a_hash_straight_from_publish_applies_without_a_json_round_trip
    mount = TaskProgress.new("web").mount("Job")
    child = TaskProgress.new("job", outputs: [TaskProgress::Outputs::Publish.new(Struct.new(:mount) { def publish(_, payload) = mount << payload }.new(mount))])
    child.subtask("A") { it.update_to(percent: 50) }
    assert_equal :done, mount.task.subtasks.first.status
  end

  def test_a_squashed_run_relayed_as_a_hash_applies_too
    mount = TaskProgress.new("web").mount("Job")
    stream = Struct.new(:mount) { def publish(_, payload) = mount << payload }.new(mount)
    buffered = TaskProgress::Outputs::Buffered.new(TaskProgress::Outputs::Publish.new(stream), interval: 0.05)
    child = TaskProgress.new("job", outputs: [buffered])
    child.subtask("A") { |a| 20.times { a.update_to(percent: it) } }
    child.done!
    buffered.close
    assert_equal :done, mount.task.status
    assert_equal :done, mount.task.subtasks.first.status
  end

  def test_a_reset_replaces_the_subtree_whole
    local = TaskProgress.new("local")
    mount = local.mount("Engine")
    first, first_batches = remote
    first.subtask("Old")
    first_batches.each { mount << it }

    restarted, = remote
    restarted.subtask("New").update_to(percent: 70)
    mount << restarted.log.squashed
    assert_equal ["New"], mount.task.subtasks.map(&:name)
    assert_equal 70, mount.task.subtasks.first.percent
  end

  def test_a_batch_from_another_log_without_a_reset_is_a_gap
    local = TaskProgress.new("local")
    mount = local.mount("Engine")
    one, one_batches = remote
    one_batches.each { mount << it }
    other, other_batches = remote
    other.subtask("x")
    assert_equal :gap, mount << other_batches.last
  end

  def test_a_batch_that_does_not_apply_is_rejected_whole
    local = TaskProgress.new("local")
    mount = local.mount("Engine")
    child, batches = remote
    batches.each { mount << it }
    bogus = TaskProgress::Batch.new(log: child.log.id, prev: child.log.seq, seq: child.log.seq + 1, at: 0.0, events: [
      TaskProgress::Event.new(path: [], op: :note, value: "fine"),
      TaskProgress::Event.new(path: [7, 7], op: :set, value: 10)
    ])
    seq = local.log.seq
    assert_equal :rejected, mount << bogus
    assert_equal seq, local.log.seq
    assert_nil mount.task.message
  end

  def test_garbage_is_rejected
    mount = TaskProgress.new("local").mount("Engine")
    assert_equal :rejected, mount << "not json"
    assert_equal :rejected, mount << {"prev" => "x"}
    assert_equal :rejected, mount << 42
  end

  def test_depth_is_bounded_after_prefixing
    local = TaskProgress.new("local")
    deep = (TaskProgress::Wire::MAX_DEPTH - 1).times.reduce(local) { |t, i| t.subtask("d#{i}") }
    mount = deep.mount("Engine")
    child, batches = remote
    child.subtask("one level too many")
    assert_equal :applied, mount << batches.first
    assert_equal :rejected, mount << batches.last
  end

  # A grandchild relayed through a child into the top: each hop prefixes once
  def test_mounts_compose_across_hops
    top = TaskProgress.new("top")
    top_mount = top.mount("Child")

    middle_batches, middle_output = recording
    middle = TaskProgress.new("middle", outputs: [middle_output], log: ticking_log)
    middle.subtask("Own work").done!
    middle_mount = middle.mount("Grandchild")

    grandchild, grand_batches = remote
    grandchild.subtask("Leaf", total: 4).advance!(3)
    grand_batches.each { middle_mount << it }
    middle_batches.each { top_mount << it }

    leaf = top.log.snapshot[[0, 1, 0]]
    assert_equal "Leaf", leaf.name
    assert_equal 3, leaf.count
    assert_equal "Grandchild", top.log.snapshot[[0, 1]].name
  end

  def test_a_mount_follows_ndjson_off_an_io
    io = StringIO.new
    child = TaskProgress.new("child", outputs: [TaskProgress::Outputs::NDJSON.new(io)])
    child.subtask("A") { it.update_to(percent: 50) }
    mount = TaskProgress.new("local").mount("Engine")
    mount.follow(StringIO.new(io.string))
    assert_equal :done, mount.task.subtasks.first.status
  end
end
