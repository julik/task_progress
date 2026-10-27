require_relative "test_helper"

class LogTest < Minitest::Test
  include TestHelpers

  # Drives a tree at random through the public API - including transactions that blow up
  # halfway - and returns the root and every batch it committed
  def random_run(seed, steps: 300)
    rng = Random.new(seed)
    batches, output = recording
    root = TaskProgress.new("root", outputs: [output], log: ticking_log, expect: rng.rand(0..3))
    live = [root]
    steps.times do
      task = live.sample(random: rng)
      begin
        case rng.rand(10)
        when 0, 1 then live << task.subtask("t#{rng.rand(100)}", total: [nil, rng.rand(1..20)].sample(random: rng),
          weight: [nil, rng.rand(1..4)].sample(random: rng), indeterminate: rng.rand(8).zero?, expect: [nil, 2].sample(random: rng))
        when 2 then task.update_to(percent: rng.rand(0..99), message: ["m#{rng.rand(9)}", nil].sample(random: rng))
        when 3 then task.advance!(rng.rand(1..3))
        when 4 then task.note("n#{rng.rand(99)}")
        when 5 then task.done!
        when 6 then task.fail!(RuntimeError.new("e#{rng.rand(9)}"), input: true)
        when 7 then task.total = rng.rand(1..30)
        when 8
          root.transaction do
            task.update_to(percent: rng.rand(0..99))
            task.subtask("in-tx")
            raise "abandon" if rng.rand(2).zero?
          end
        when 9 then task.update_to(percent: 100)
        end
      rescue ArgumentError, RuntimeError
        nil
      end
    end
    [root, batches]
  end

  def test_folding_the_squash_gives_the_state_back
    20.times do |seed|
      root, _ = random_run(seed)
      state = root.log.snapshot
      assert_equal state.to_h, TaskProgress::State.fold(state.squash).to_h, "seed #{seed}"
    end
  end

  def test_squashing_a_prefix_first_changes_nothing
    20.times do |seed|
      root, batches = random_run(seed)
      cut = Random.new(seed).rand(1...batches.length)
      squashed_prefix = fold_batches(batches.first(cut)).squash
      resumed = TaskProgress::State.fold(squashed_prefix)
      resumed = fold_batches(batches.drop(cut), resumed)
      assert_equal root.log.snapshot.to_h, resumed.to_h, "seed #{seed}, cut at #{cut}"
      assert_equal root.log.snapshot.squash, resumed.squash
    end
  end

  def test_the_batches_fold_into_the_state_and_survive_the_wire
    20.times do |seed|
      root, batches = random_run(seed)
      assert_equal root.log.snapshot.to_h, fold_batches(batches).to_h
      over_the_wire = batches.map { TaskProgress::Wire.parse(TaskProgress::Wire.dump(it)) }
      assert_equal root.log.snapshot.to_h, fold_batches(over_the_wire).to_h, "seed #{seed}"
    end
  end

  def test_percents_agree_after_a_squash
    10.times do |seed|
      root, _ = random_run(seed)
      folded = TaskProgress::State.fold(root.log.snapshot.squash)
      root.log.snapshot.each { |path, _| assert_equal root.log.snapshot.percent(path), folded.percent(path) }
    end
  end

  def test_seq_and_prev_chain_without_gaps
    _, batches = random_run(1)
    assert_equal 0, batches.first.prev
    assert(batches.each_cons(2).all? { |a, b| b.prev == a.seq && b.seq == a.seq + 1 })
  end

  def test_a_late_output_gets_the_squash_then_the_rest_without_overlap
    root = TaskProgress.new("root")
    a = root.subtask("A")
    a.update_to(percent: 30)
    batches, output = recording
    root.log.add_output(output)
    a.update_to(percent: 60)
    assert_equal [0, 3], [batches.first.prev, batches.first.seq]
    assert batches.first.events.all? { it.op == :put }
    assert_equal [3, 4], [batches.last.prev, batches.last.seq]
    assert_equal 2, batches.length
  end

  def test_adding_an_output_while_others_commit_never_duplicates_or_drops
    root = TaskProgress.new("root")
    workers = 4.times.map { root.subtask("w#{it}", total: 200) }
    threads = workers.map { |w| Thread.new { 200.times { w.tick! } } }
    late = 5.times.map do
      sleep 0.001
      batches, output = recording
      root.log.add_output(output)
      batches
    end
    threads.each(&:join)
    late.each do |batches|
      assert batches.first.reset?
      assert(batches.each_cons(2).all? { |a, b| b.prev == a.seq })
      assert_equal root.log.snapshot.to_h.transform_values { it.except(:opened_at) },
        fold_batches(batches).to_h.transform_values { it.except(:opened_at) }
    end
  end

  def test_outputs_run_outside_the_lock_so_they_may_read_and_write_the_tree
    seen = []
    root = nil
    root = TaskProgress.new("root", outputs: [->(batch, log) {
      seen << log.snapshot.percent
      root.note("echo") if batch.events.any? { it.op == :set } && root
    }])
    root.update_to(percent: 40)
    assert_equal "echo", root.message
    assert_equal [0, 40, 40], seen
  end

  def test_a_raising_output_does_not_break_the_others_or_the_work
    batches, output = recording
    errors = []
    log = TaskProgress::Log.new
    log.on_output_error = ->(error, _) { errors << error.message }
    root = TaskProgress.new("root", log:, outputs: [->(*) { raise "broken output" }, output])
    root.update_to(percent: 10)
    assert_equal 2, batches.length
    assert_equal ["broken output"] * 2, errors
  end

  def test_a_slow_output_never_delays_a_reader
    gate = Queue.new
    root = TaskProgress.new("root")
    root.log.add_output(->(batch, _) { gate.pop if batch.events.any? { it.op == :set } }, replay: false)
    writer = Thread.new { root.update_to(percent: 10) }
    sleep 0.01
    assert_equal 10, root.percent, "the change is in while its output is still busy"
    gate << :go
    writer.join
  end

  # Thread#raise - and Timeout, which uses it - may land anywhere: between a change and its
  # commit, or halfway through handing a batch to the outputs. Either would leave the log and
  # what the outputs saw disagreeing with the state
  def test_asynchronous_interrupts_never_split_a_commit_or_a_delivery
    batches, output = recording
    other_batches, other_output = recording
    root = TaskProgress.new("root", outputs: [output, ->(*) { Thread.pass }, other_output])
    tasks = 4.times.map { root.subtask("t#{it}", total: 1_000_000) }
    stop = false
    worker = Thread.new do
      until stop
        begin
          root.transaction { tasks.each { it.tick! } }
        rescue Interrupt
          nil
        end
      end
    end
    300.times do
      sleep(rand * 0.0005)
      worker.raise(Interrupt)
    end
    stop = true
    worker.join

    assert(batches.each_cons(2).all? { |a, b| b.prev == a.seq }, "no batch went missing")
    assert_equal batches.map(&:seq), other_batches.map(&:seq), "every output saw every batch: #{(batches.map(&:seq) - other_batches.map(&:seq)).inspect} of #{batches.length}"
    assert_equal root.log.snapshot.to_h, fold_batches(batches).to_h
    counts = tasks.map(&:count)
    assert_equal 1, counts.uniq.length, "a transaction landed whole or not at all: #{counts.inspect}"
  end

  def test_a_snapshot_is_frozen
    root = TaskProgress.new("root")
    root.subtask("A")
    snapshot = root.log.snapshot
    assert snapshot.frozen?
    assert snapshot[[0]].frozen?
    assert_raises(FrozenError) { snapshot[[0]].name = "x" }
  end
end
