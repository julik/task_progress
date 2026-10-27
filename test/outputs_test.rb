require_relative "test_helper"

class OutputsTest < Minitest::Test
  include TestHelpers

  class FakeStream
    attr_reader :published

    def initialize = @published = []

    def publish(name, payload) = @published << [name, payload]
  end

  LINE = /\A\[ *\d+% +[\d.]+s\] /

  def test_an_execution_log_says_endings_at_once_and_only_the_newest_news
    io = StringIO.new
    log = TaskProgress::Outputs::ExecutionLog.new(io, interval: 0.3)
    root = TaskProgress.new("demo", outputs: [log])
    a, b = root.subtask("A"), root.subtask("B", total: 50)
    20.times { a.note("note #{it}") }
    a.puts("Said")
    a.done!
    lines = io.string.lines.map { it.sub(LINE, "").chomp }
    assert_equal ["demo › A: note 0", "demo › A: Said", "✓ demo › A  0.0s"], lines, "the first news at once, the rest held back"

    10.times { b.tick! }
    sleep 0.45
    assert_equal "demo › B 10/50", io.string.lines.last.sub(LINE, "").chomp, "held news goes out when the interval is up"
    b.fail!("out of disk")
    root.done!
    log.close
    assert_equal ["✗ demo › B: out of disk", "✓ demo  0.5s"], io.string.lines.last(2).map { it.sub(LINE, "").chomp.sub(/0\.\ds\z/, "0.5s") }
    assert(io.string.lines.all? { it.match?(LINE) && it.end_with?("\n") })
    refute_includes io.string, "\e", "never a terminal control"
  end

  def test_an_execution_log_says_only_the_top_of_what_ended_together
    io = StringIO.new
    root = TaskProgress.new("demo", outputs: [TaskProgress::Outputs::ExecutionLog.new(io)])
    job = root.subtask("Job")
    3.times { job.subtask("step #{it}") }
    job.cancel!("Ctrl-C")
    root.subtask("Other").fail!("nope")
    assert_equal ["⊘ demo › Job: Ctrl-C", "✗ demo › Other: nope"], io.string.lines.map { it.sub(LINE, "").chomp }
  end

  def test_an_execution_log_says_it_is_still_going
    io = StringIO.new
    log = TaskProgress::Outputs::ExecutionLog.new(io, interval: 0.05, heartbeat: 0.2)
    root = TaskProgress.new("demo", outputs: [log])
    root.note("Starting")
    sleep 0.5
    log.close
    assert_operator io.string.scan("demo: still going").length, :>=, 1
  end

  def test_ndjson_writes_lines_a_mount_can_follow
    io = StringIO.new
    root = TaskProgress.new("demo", outputs: [TaskProgress::Outputs::NDJSON.new(io)])
    root.subtask("A").update_to(percent: 10)
    lines = io.string.lines
    assert_equal 3, lines.length
    assert(lines.all? { TaskProgress::Wire.parse(it) })
  end

  def test_publish_hands_a_json_ready_hash_to_a_stream
    stream = FakeStream.new
    root = TaskProgress.new("demo", outputs: [TaskProgress::Outputs::Publish.new(stream)])
    root.subtask("A").done!
    assert_equal %w[task_progress] * 3, stream.published.map(&:first)
    payloads = stream.published.map { JSON.parse(JSON.generate(it.last)) }
    mount = TaskProgress.new("web").mount("Job")
    payloads.each { assert_equal :applied, mount << it }
    assert_equal :done, mount.task.subtasks.first.status
  end

  def test_buffered_merges_what_piles_up_and_keeps_the_chain
    received = []
    gate = Queue.new
    slow = ->(batch, _) { gate.pop; received << batch }
    buffered = TaskProgress::Outputs::Buffered.new(slow, interval: 0)
    root = TaskProgress.new("demo", outputs: [buffered])
    a = root.subtask("A")
    10.times { a.update_to(percent: it * 5) }
    11.times { gate << :go }
    buffered.close
    assert_operator received.length, :<, 12, "batches were merged"
    assert_equal 0, received.first.prev
    assert(received.each_cons(2).all? { |x, y| y.prev == x.seq })
    assert_equal root.log.snapshot.to_h, fold_batches(received).to_h
  end

def test_a_squashed_run_lands_a_reader_exactly_where_the_run_left_off
  20.times do |seed|
    rng = Random.new(seed)
    batches, output = recording
    root = TaskProgress.new("demo", outputs: [output], log: ticking_log)
    live = [root]
    200.times do
      task = live.sample(random: rng)
      case rng.rand(5)
      when 0 then live << task.subtask("t")
      when 1 then task.update_to(percent: rng.rand(99))
      when 2 then task.done!
      when 3 then root.log.append(TaskProgress::Event.new(path: task.path, op: :prune)) && live.select! { root.log.snapshot.key?(it.path) }
      when 4 then task.note("n")
      end
    rescue ArgumentError
      nil
    end
    squasher = TaskProgress::Outputs::Buffered::Squasher.new
    cuts = [0, *batches.each_index.to_a.sample(5, random: rng).sort, batches.length].uniq
    squashed = cuts.each_cons(2).map { |from, to| squasher.squash(batches[from...to]) }
    assert(squashed.each_cons(2).all? { |a, b| b.prev == a.seq })
    assert_equal root.log.snapshot.to_h, fold_batches(squashed).to_h, "seed #{seed}"
  end
end

  def test_buffered_keeps_a_slow_output_off_the_workers
    gate = Queue.new
    buffered = TaskProgress::Outputs::Buffered.new(->(*) { gate.pop }, interval: 0)
    root = TaskProgress.new("demo", outputs: [buffered])
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    100.times { root.note("n#{it}") }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
    loop { gate << :go; break if gate.num_waiting.zero? && (sleep(0.01) || true) && gate.num_waiting.zero? }
    200.times { gate << :go }
    buffered.close
  end

  def test_terminal_draws_the_tree_and_redraws_in_place
    io = StringIO.new
    term = TaskProgress::Outputs::Terminal.new(io, interval: nil, clock: -> { 1_700_000_010.0 })
    root = TaskProgress.new("Import", outputs: [term], log: ticking_log)
    rows = root.subtask("Rows", total: 200)
    root.subtask("Waiting", indeterminate: true).note("for the API")
    rows.advance!(50, message: "row 50")
    frames = io.string.split(/\e\[\d+A\e\[J/)
    last = frames.last.lines.map(&:chomp)
    assert_match(/\A⠋ Import  █+░+  13%/, last[0])
    assert_match(/\A  ⠋ Rows  █{5}░+ 50\/200  .*row 50\z/, last[1])
    assert_match(/\A  ⠋ Waiting  6.0s  for the API\z/, last[2])
    assert_operator frames.length, :>, 1
  end

  def test_terminal_folds_finished_subtrees_and_shows_failures
    io = StringIO.new
    term = TaskProgress::Outputs::Terminal.new(io, interval: nil)
    root = TaskProgress.new("Import", outputs: [term])
    root.subtask("Done") { |t| t.subtask("Hidden").done! }
    root.subtask("Broken") { raise "no disk" } rescue nil
    root.subtask("Running").update_to(percent: 5)
    lines = term.lines(root.log.snapshot)
    assert_equal 4, lines.length
    refute(lines.any? { it.include?("Hidden") })
    assert_match(/✓ Done/, lines[1])
    assert_match(/✗ Broken.*no disk/, lines[2])
  end

  def test_terminal_keeps_the_way_down_to_a_failure_once_the_root_fails
    term = TaskProgress::Outputs::Terminal.new(StringIO.new, interval: nil)
    root = TaskProgress.new("Import")
    begin
      root.run do
        root.subtask("Fine") { it.subtask("Hidden").done! }
        root.subtask("Engine") do |engine|
          engine.subtask("Unpacking").done!
          engine.subtask("Marking") { raise "bad entry" }
        end
      end
    rescue RuntimeError
      nil
    end
    lines = term.lines(root.log.snapshot)
    assert_equal ["✗ Import", "  ✗ Engine", "    ✗ Marking"], lines.map { it[/\A *\S \S+/] }
    assert_match(/bad entry/, lines.last)
  end

  def test_terminal_sheds_finished_lines_first_when_short_of_room
    term = TaskProgress::Outputs::Terminal.new(StringIO.new, interval: nil)
    root = TaskProgress.new("R")
    5.times { root.subtask("done #{it}").done! }
    3.times { root.subtask("busy #{it}").update_to(percent: 10) }
    lines = term.lines(root.log.snapshot, height: 5)
    assert_equal 4, lines.length
    assert_match(/R/, lines[0])
    assert_equal 3, lines.count { it.include?("busy") }
  end

  def test_terminal_says_how_many_it_could_not_fit
    term = TaskProgress::Outputs::Terminal.new(StringIO.new, interval: nil)
    root = TaskProgress.new("R")
    10.times { root.subtask("busy #{it}").update_to(percent: 10) }
    lines = term.lines(root.log.snapshot, height: 5)
    assert_equal 4, lines.length
    assert_equal "  … 8 more", lines.last
  end

  def test_terminal_fits_the_width
    term = TaskProgress::Outputs::Terminal.new(StringIO.new, interval: nil)
    root = TaskProgress.new("R")
    root.subtask("x" * 300).note("y" * 300)
    term.lines(root.log.snapshot, width: 40).each { assert_operator it.length, :<, 40 }
  end

  def test_terminal_leaves_the_last_frame_or_erases_it
    io = StringIO.new
    root = TaskProgress.new("R", outputs: [TaskProgress::Outputs::Terminal.new(io, interval: nil)])
    root.subtask("A") { it.update_to(percent: 50) }
    root.done!
    assert_match(/✓ R .*100%.*\n\z/, io.string)

    io = StringIO.new
    root = TaskProgress.new("R", outputs: [TaskProgress::Outputs::Terminal.new(io, interval: nil, erase: true)])
    root.update_to(percent: 50)
    root.done!
    assert io.string.end_with?("\e[1A\e[J")
  end

  def test_terminal_ticks_on_its_own
    io = StringIO.new
    term = TaskProgress::Outputs::Terminal.new(io, interval: 0.01)
    root = TaskProgress.new("R", outputs: [term])
    root.subtask("Waiting", indeterminate: true).note("…")
    sleep 0.1
    root.done!
    term.close
    spinners = io.string.scan(/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] Waiting/).uniq
    assert_operator spinners.length, :>, 1, "the spinner turned without any batch arriving"
  end

  def test_cli_picks_its_output
    tty = Class.new(StringIO) { def tty? = true }
    ci = ENV.delete("CI")
    assert_kind_of TaskProgress::Outputs::Terminal, TaskProgress.cli_output(io: tty.new, quiet: false)
    ENV["CI"] = "true"
    assert_kind_of TaskProgress::Outputs::ExecutionLog, TaskProgress.cli_output(io: tty.new, quiet: false), "nobody watches a CI terminal redraw"
    ENV["CI"] = ci
    assert_kind_of TaskProgress::Outputs::ExecutionLog, TaskProgress.cli_output(io: StringIO.new, quiet: false)
    assert_nil TaskProgress.cli_output(io: StringIO.new, quiet: true)
  end

  def test_cli_with_a_block_runs_it_and_returns_its_value
    io = StringIO.new
    assert_equal :result, TaskProgress.cli("job", io:) { |root| root.subtask("A") { :ignored } && :result }
    assert_equal ["✓ job › A", "✓ job"], io.string.lines.map { it.sub(LINE, "").sub(/  [\d.]+s$/, "").chomp }
    assert_raises(RuntimeError) { TaskProgress.cli("job", io:) { raise "boom" } }
    assert io.string.end_with?("✗ job: boom\n")
  end
end
