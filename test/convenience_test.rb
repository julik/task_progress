require_relative "test_helper"

class ConvenienceTest < Minitest::Test
  include TestHelpers

  def test_a_bar_finishes_by_itself_at_its_total
    io = StringIO.new
    bar = TaskProgress.bar("Importing", total: 3, io:)
    3.times { bar.tick! }
    assert bar.done?
    bar.tick! # a collection longer than its size said
    assert_equal 3, bar.count
    assert_equal ["Importing 1/3", "✓ Importing  0.0s"], io.string.lines.map { it.sub(/\A\[.*?\] /, "").chomp }
  end

  def test_a_bar_without_a_total_counts_and_spins
    bar = TaskProgress.bar("Streaming", quiet: true)
    5.times { bar.tick! }
    assert bar.node.indeterminate
    assert_equal 5, bar.count
    refute bar.finished?
  end

  def test_a_bar_is_finished_when_the_program_ends
    script = <<~RUBY
      bar = TaskProgress.bar("Streaming", io: $stdout)
      bar.tick!
    RUBY
    out = IO.popen([RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-rtask_progress", "-e", script], &:read)
    assert_match(/✓ Streaming/, out.lines.last)

    failing = IO.popen([RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-rtask_progress", "-e", "#{script}\nraise 'disk full'", err: File::NULL], &:read)
    assert_match(/✗ Streaming: disk full/, failing.lines.last)
  end

  def test_iterate_counts_a_subtask_through_a_collection
    root = TaskProgress.new("root")
    seen = []
    returned = root.iterate(%w[a b c], "Letters") { seen << it }
    letters = root.subtasks.first
    assert_equal %w[a b c], seen
    assert_equal %w[a b c], returned
    assert_equal ["Letters", 3, 3, :done], [letters.name, letters.count, letters.total, letters.status]
  end

  def test_iterate_without_a_block_is_an_enumerator
    root = TaskProgress.new("root")
    enumerator = root.iterate(1..4, "Numbers")
    assert_equal :pending, root.subtasks.first.status, "nothing runs until it is consumed"
    assert_equal [2, 4, 6, 8], enumerator.map { it * 2 }
    assert root.subtasks.first.done?
  end

  def test_iterate_takes_the_size_and_never_counts
    root = TaskProgress.new("root")
    endless = Enumerator.new { |y| 3.times { y << it } } # no size
    root.iterate(endless, "Stream") { nil }
    stream = root.subtasks.first
    assert_nil stream.total
    assert_equal 3, stream.count
    assert stream.done?

    lazy = (1..Float::INFINITY).lazy.map { it * 2 }
    taken = root.iterate(lazy, "Lazy").first(3)
    assert_equal [2, 4, 6], taken
  end

  def test_iterate_fails_the_task_with_the_error
    root = TaskProgress.new("root")
    assert_raises(RuntimeError) { root.iterate([1, 2], "Rows") { raise "row 2 is bad" if it == 2 } }
    rows = root.subtasks.first
    assert_equal :failed, rows.status
    assert_equal "row 2 is bad", rows.error[:message]
    assert_equal 1, rows.count
  end

  def test_iterate_on_a_bare_bar_counts_on_the_bar_itself
    io = StringIO.new
    result = TaskProgress.iterate([1, 2, 3, 4], "Rows", io:) { nil }
    assert_equal [1, 2, 3, 4], result
    assert_match(/\A\[100% +[\d.]+s\] ✓ Rows  [\d.]+s\z/, io.string.lines.last.chomp)
  end

  def test_with_progress_is_there_for_files_that_ask_for_it
    refute_respond_to [1], :with_progress
    assert_equal [2, 4], RefinedLoop.double([1, 2])
  end

  def test_puts_says_a_line_that_the_tree_does_not_keep
    batches, output = recording
    root = TaskProgress.new("root", outputs: [output])
    rows = root.subtask("Rows")
    rows.puts("Skipped row 12")
    said = batches.last.events.first
    assert_equal [rows.path, :say, "Skipped row 12"], [said.path, said.op, said.value]
    refute(root.log.squashed.events.any? { it.op == :say })
    assert_equal TaskProgress::Wire.parse(TaskProgress::Wire.dump(batches.last)), batches.last
    assert_nil TaskProgress::Wire.parse(JSON.generate(log: "x", prev: 0, seq: 1, ops: [[[], "say", 12]]))
  end

  def test_a_mount_and_a_buffer_pass_what_was_said
    child, batches = remote_with_say
    mount = TaskProgress.new("local").mount("Child")
    said = []
    mount.log.add_output(->(batch, _) { said.concat(batch.events.select { it.op == :say }) }, replay: false)
    batches.each { mount << it }
    assert_equal [[*mount.path, *child.subtasks.first.path]], said.map(&:path)

    squashed = TaskProgress::Squasher.new.squash(batches)
    assert_equal ["Hello from the child"], squashed.events.select { it.op == :say }.map(&:value)
  end

  def test_the_terminal_prints_what_was_said_above_the_tree
    io = StringIO.new
    term = TaskProgress::TerminalOutput.new(io, interval: nil)
    root = TaskProgress.new("Import", outputs: [term])
    root.subtask("Rows").puts("Skipped row 12")
    root.done!
    text = io.string.gsub(/\e\[\d+A\e\[J/, "")
    assert_match(/^Skipped row 12\n.*Import/, text)
    assert_equal "Skipped row 12", text.lines.grep(/Skipped/).first.chomp, "it is printed once, and never redrawn"
  end

  def test_the_terminal_shows_rate_and_time_left
    now = 1_700_000_000.0
    io = StringIO.new
    term = TaskProgress::TerminalOutput.new(io, interval: nil, clock: -> { now })
    root = TaskProgress.new("Import", outputs: [term], log: TaskProgress::Log.new(clock: -> { now }))
    rows = root.subtask("Rows", total: 100)
    rows.tick!
    now += 10
    rows.advance!(19)
    assert_match(/Rows  █+░+ 20\/100  2\.0\/s  ETA 40\.0s  10\.0s/, term.lines(root.log.snapshot)[1])
  end

  private

  def remote_with_say
    batches, output = recording
    child = TaskProgress.new("child", outputs: [output])
    child.subtask("Work").puts("Hello from the child")
    [child, batches]
  end
end

module RefinedLoop
  using TaskProgress::Refinements

  def self.double(items) = items.with_progress("Doubling", quiet: true).map { it * 2 }
end
