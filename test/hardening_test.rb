require_relative "test_helper"
require "timeout"

# What adversarial review found - each a test, so it stays found
class HardeningTest < Minitest::Test
  include TestHelpers

  def test_infinity_never_gets_into_a_tree
    line = %({"v":1,"log":"x","prev":0,"seq":1,"at":1e999,"ops":[[[],"put",{"name":"x","status":"active","opened_at":1e999}]]})
    batch = TaskProgress::Wire.parse(line)
    assert_equal 0.0, batch.at
    assert_nil batch.events.first.value[:opened_at]
    mount = TaskProgress.new("local").mount("Remote")
    mount << batch
    assert TaskProgress::Wire.dump(mount.log.squashed), "the tree can still be written out"
    assert_nil TaskProgress::Wire.parse(%({"v":1,"log":"x","prev":0,"seq":1,"ops":[[[],"set",1e999]]})), "nor is it a percent"
  end

  def test_the_execution_log_says_the_ending_even_when_the_tree_ran_ahead
    io = StringIO.new
    output = TaskProgress::ExecutionLogOutput.new(io, interval: 0)
    root = TaskProgress.new("Import")
    log = root.log
    first = TaskProgress::Batch.new(log: log.id, prev: 0, seq: 1, at: 1.0, events: [TaskProgress::Event.new(path: [], op: :note, value: "halfway")])
    root.done! # the tree has finished before the earlier batch is delivered
    output.call(first, log)
    output.call(TaskProgress::Batch.new(log: log.id, prev: 1, seq: 2, at: 2.0, events: [TaskProgress::Event.new(path: [], op: :done)]), log)
    output.close
    assert_includes io.string, "✓ Import"
  end

  def test_a_carriage_return_does_not_cut_a_turbo_frame
    root = TaskProgress.new("Download")
    root.subtask("50%\r100%\revent: nope").done!
    root.done!
    renderer = TaskProgress::HTMLRenderer.new(id: "tree")
    chunks = []
    TaskProgress::TurboSSE.new(root, renderer:).each { chunks << it }
    frame = chunks.find { it.include?("turbo-stream action=\"replace\"") }
    assert(frame.split("\n").reject(&:empty?).all? { it.start_with?("data: ") }, "every line of the event is data")
  end

  def test_a_task_that_is_gone_ends_its_streams
    root = TaskProgress.new("Root")
    step = root.subtask("Step")
    root.log.transaction { |tx| tx << TaskProgress::Event.new(path: [], op: :prune) }
    chunks = []
    Timeout.timeout(2) { TaskProgress::SSE.new(step).each { chunks << it } }
    assert_equal 0, TaskProgress::Wire.parse(chunks.last[/^data: (.*)$/, 1]).events.length, "an empty tree, and the end"
    status, headers, = TaskProgress::Poll.response(step)
    assert_equal 200, status
    assert_equal 304, TaskProgress::Poll.response(step, {"HTTP_IF_NONE_MATCH" => headers["etag"], "QUERY_STRING" => "wait=5"}).first
    renderer = TaskProgress::HTMLRenderer.new(id: "tree")
    Timeout.timeout(2) { TaskProgress::TurboSSE.new(step, renderer:).each { nil } }
  end

  def test_a_weak_etag_still_matches
    root = TaskProgress.new("Polled")
    _, headers, = TaskProgress::Poll.response(root)
    assert_equal 304, TaskProgress::Poll.response(root, {"HTTP_IF_NONE_MATCH" => "W/#{headers["etag"]}"}).first
    assert_equal 304, TaskProgress::Poll.response(root, {"HTTP_IF_NONE_MATCH" => %("other", #{headers["etag"]})}).first
  end

  def test_iterate_advances_in_its_steps
    adds = []
    root = TaskProgress.new("Download", outputs: [->(batch, _) { adds.concat(batch.events.select { it.op == :add }.map(&:value)) }])
    root.iterate(100.times, "Chunks", total: 100 * 65_536, step: 65_536) { nil }
    assert_equal 100, adds.length, "every chunk is more than a thousandth"
  end

  def test_a_removed_output_hears_nothing_more
    heard = []
    root = TaskProgress.new("Root")
    listener = ->(batch, _) { heard << batch.seq }
    # The first output removes the second while a batch is on its way to both
    root.log.add_output(->(batch, log) { log.remove_output(listener) if batch.events.any? { it.value == "stop" } }, replay: false)
    root.log.add_output(listener, replay: false)
    root.note("go")
    root.note("stop")
    root.note("after")
    assert_equal [2], heard
  end

  def test_siblings_that_finished_together_fold_alike_in_ruby_and_in_the_browser
    root = TaskProgress.new("Root")
    files = root.subtask("Files")
    20.times { files.subtask("f#{it}") }
    files.done! # all twenty finish in one transaction, at one time
    ruby = root.log.snapshot.rows.map { |_, node| node.name }
    assert_equal ["Root", "Files", "17 more done", "f0", "f1", "f2"], ruby
  end
end
