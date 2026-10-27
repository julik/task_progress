require_relative "test_helper"

class SSETest < Minitest::Test
  def read_frames(body)
    frames = []
    body.each { frames << it }
    frames
  end

  def batch_of(frame) = TaskProgress::Wire.parse(frame[/^data: (.*)$/, 1])

  def test_streams_the_squash_then_live_batches_until_the_root_finishes
    root = TaskProgress.new("job")
    a = root.subtask("A")
    a.update_to(percent: 30)
    reader = Thread.new { read_frames(TaskProgress::SSE.new(root)) }
    sleep 0.02
    a.update_to(percent: 60)
    root.done!
    frames = reader.value

    assert_equal "retry: 2000\n\n", frames.first
    batches = frames.drop(1).map { batch_of(it) }
    assert batches.first.reset?
    assert_equal root.log.seq, batches.last.seq
    assert(batches.each_cons(2).all? { |x, y| y.prev == x.seq })
    assert_match(/\Aid: \d+\nevent: batch\ndata: \{.*\}\n\n\z/, frames[1])
    assert_empty root.log.instance_variable_get(:@outputs), "the stream let go of the log"
  end

  def test_streams_a_subtask_as_its_own_tree_until_it_finishes
    root = TaskProgress.new("job")
    root.subtask("Other")
    upload = root.subtask("Upload")
    upload.subtask("Part")
    reader = Thread.new { read_frames(TaskProgress::SSE.new(upload)) }
    sleep 0.02
    root.subtasks.first.note("not ours")
    upload.done!
    batches = reader.value.drop(1).map { batch_of(it) }

    assert_equal [[], [0]], batches.first.events.map(&:path)
    assert_equal [[[], :done]], batches.last.events.map { [it.path, it.op] }
    assert_equal 2, batches.length
    refute root.finished?, "the stream ends with the subtask, not the root"
    assert_empty root.log.instance_variable_get(:@outputs)
  end

  # The snapshot runs ahead of delivery: with an output before ours still busy with the last
  # batch, the tree already reads finished while that batch has not reached us
  def test_the_stream_does_not_end_before_the_finishing_batch_arrives
    gate = Queue.new
    root = TaskProgress.new("job")
    root.log.add_output(->(batch, _) { gate.pop if batch.events.any? { it.path.empty? && it.op == :done } }, replay: false)
    a = root.subtask("A")
    reader = Thread.new { read_frames(TaskProgress::SSE.new(root)) }
    sleep 0.02
    finisher = Thread.new { root.done! }
    a.update_to(percent: 10) rescue nil
    sleep 0.02
    gate << :go
    finisher.join
    frames = reader.value
    assert_includes frames.last, '[[],"done"]', "the last frame carries the root finishing"
  end

  def test_a_finished_tree_streams_once_and_ends
    root = TaskProgress.new("job")
    root.done!
    frames = read_frames(TaskProgress::SSE.new(root))
    assert_equal 2, frames.length
  end

  def test_pings_while_idle
    root = TaskProgress.new("job")
    reader = Thread.new { read_frames(TaskProgress::SSE.new(root, heartbeat: 0.01)) }
    sleep 0.05
    root.done!
    assert_includes reader.value, ": ping\n\n"
  end

  def test_rack_response
    status, headers, body = TaskProgress::SSE.response(TaskProgress.new("job").tap(&:done!))
    assert_equal 200, status
    assert_equal "text/event-stream", headers["content-type"]
    assert_respond_to body, :each
  end
end
