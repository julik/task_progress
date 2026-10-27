require_relative "test_helper"

# A tree created in one place and worked on in another, through a stream - the same tests for
# every kind of stream there is
module StreamBehaviour
  include TestHelpers

  def teardown
    @closing&.each { it.log.close }
  end

  def following(key, **)
    TaskProgress.follow(key, stream: @stream, poll: 0.05, **).tap { (@closing ||= []) << it }
  end

  def wait_for(seconds = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until (value = yield)
      raise Minitest::Assertion, "Waited #{seconds}s in vain" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    value
  end

  def test_entries_are_read_after_an_id_and_trimmed_from_the_front
    key = "tp-test:#{rand(36**8).to_s(36)}"
    ids = %w[a b c].map { @stream.append(key, it) }
    assert_equal %w[a b c], @stream.read(key).map(&:last)
    assert_equal %w[b c], @stream.read(key, after: ids[0]).map(&:last)
    assert_equal [], @stream.read(key, after: ids[2])
    @stream.trim(key, before: ids[1])
    assert_equal %w[b c], @stream.read(key).map(&:last)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal [], @stream.read(key, after: ids[2], timeout: 0.1)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.09, "waited for one"
    Thread.new {
      sleep 0.05
      @stream.append(key, "d")
    }
    assert_equal ["d"], @stream.read(key, after: ids[2], timeout: 2).map(&:last), "and woke when one came"
  ensure
    @stream.delete(key)
  end

  def test_values_are_kept_and_expire
    key = "tp-test:#{rand(36**8).to_s(36)}"
    @stream.set(key, "x", expires_in: 0.1)
    assert_equal "x", @stream.get(key)
    sleep 0.15
    assert_nil @stream.get(key)
  end

  def test_a_tree_handed_off_waits_until_a_worker_takes_it_up
    import = TaskProgress.handoff("Importing", stream: @stream, cancelable: true)
    assert_match(/\Atask_progress:\{[0-9a-z]{10}\}\z/, import.key)
    viewer = following(import.key)
    assert_equal ["Importing", :pending, true], [viewer.name, viewer.status, viewer.node.cancelable], "drawn before any worker has it"

    result = TaskProgress.adopt(import.key, stream: @stream) do |root|
      assert_equal "Importing", root.name, "named as it was handed off"
      root.subtask("Rows", total: 3) { |rows| 3.times { rows.tick! } }
      :imported
    end
    assert_equal :imported, result
    wait_for { viewer.done? }
    assert_equal ["Rows"], viewer.subtasks.map(&:name)
    assert_equal 100, viewer.percent
  end

  def test_a_late_reader_starts_from_the_snapshot_and_the_stream_stays_short
    import = TaskProgress.handoff("Crunching", stream: @stream)
    root = TaskProgress.adopt(import.key, stream: @stream, interval: 0)
    items = root.subtask("Items", total: 1000)
    writer = root.log.instance_variable_get(:@outputs).first.instance_variable_get(:@output)
    writer.instance_variable_set(:@snapshot_every, 0)
    1000.times { items.tick! }
    sleep 0.2
    assert_operator @stream.read(import.key).length, :<, 50, "trimmed behind the snapshots"
    late = TaskProgress.fetch(import.key, stream: @stream)
    assert_equal [1000, :done], [late.subtasks.first.count, late.subtasks.first.status]
  ensure
    root&.log&.close
  end

  def test_a_cancel_from_a_follower_reaches_the_worker
    import = TaskProgress.handoff("Importing", stream: @stream, cancelable: true)
    viewer = following(import.key)
    started = Queue.new
    worker = Thread.new do
      TaskProgress.adopt(import.key, stream: @stream, beat: 0.05) do |root|
        started << true
        loop { root.note("working") && sleep(0.01) }
      end
    end
    started.pop
    wait_for { viewer.status == :active }
    assert_equal :canceled, viewer.request_cancel([], "changed my mind"), "the mount itself is ours to call off, and the worker is told"
    assert_nil worker.value, "the work stopped, quietly"
    wait_for { viewer.canceled? }
    assert_equal "changed my mind", viewer.message
  end

  def test_a_tree_read_once_can_still_cancel_the_work
    import = TaskProgress.handoff("Importing", stream: @stream)
    started = Queue.new
    worker = Thread.new do
      TaskProgress.adopt(import.key, stream: @stream, beat: 0.05) do |root|
        root.subtask("Rows", cancelable: true) do |rows|
          started << rows.path.join("-")
          loop { rows.note("working") && sleep(0.01) }
        end
        :carried_on
      end
    end
    path = started.pop
    assert_equal :forwarded, TaskProgress.fetch(import.key, stream: @stream).request_cancel(path, "From a page")
    assert_equal :carried_on, worker.value, "the task was called off, and the job went on"
    wait_for { TaskProgress.fetch(import.key, stream: @stream).subtasks.first.canceled? }
  end

  def test_what_the_old_writer_sends_after_a_new_one_took_over_is_ignored
    import = TaskProgress.handoff("Importing", stream: @stream)
    viewer = following(import.key)
    TaskProgress.adopt(import.key, stream: @stream) { |root| root.subtask("Real").done! }
    import.subtask("Stray")
    import.done!
    sleep 0.2
    assert_equal ["Real"], viewer.subtasks.map(&:name)
    refute viewer.node.stale, "a superseded writer is no gap"
  end

  def test_a_worker_that_dies_goes_stale_then_fails_and_a_retry_takes_over
    import = TaskProgress.handoff("Importing", stream: @stream)
    viewer = following(import.key, give_up_after: 0.3)
    sleep 0.2
    refute viewer.node.stale, "nobody has taken it up yet - that is waiting, not silence"
    root = TaskProgress.adopt(import.key, stream: @stream, beat: 0.05, interval: 0)
    root.subtask("Rows").note("half way")
    wait_for { viewer.status == :active }
    root.log.close # as good as kill -9: it stops beating, and says nothing more
    wait_for(5) { viewer.node.stale }
    wait_for(5) { viewer.failed? }
    assert_match(/Lost touch/, viewer.error[:message])

    TaskProgress.adopt(import.key, stream: @stream) do |retried|
      assert_equal 2, retried.node.attempt, "counted from what the last run left"
      retried.subtask("Rows").done!
    end
    wait_for { viewer.done? }
    assert_equal [2, false], [viewer.node.attempt, !!viewer.node.stale]
    assert_equal [["Rows", :done]], viewer.subtasks.map { [it.name, it.status] }, "the first run is gone, not mixed in"
  end

  def test_a_job_that_raises_fails_and_its_retry_starts_over
    import = TaskProgress.handoff("Importing", stream: @stream)
    viewer = following(import.key)
    assert_raises(RuntimeError) do
      TaskProgress.adopt(import.key, stream: @stream) { |root| root.subtask("Rows") && raise("boom") }
    end
    wait_for { viewer.failed? }
    assert_equal "boom", viewer.error[:message]
    TaskProgress.adopt(import.key, stream: @stream) { |root| root.subtask("Rows").done! }
    wait_for { viewer.done? }
    assert_equal [["Rows", :done]], viewer.subtasks.map { [it.name, it.status] }
  end

  def test_a_live_tree_can_mount_one_handed_off
    parent = TaskProgress.new("Nightly")
    part = TaskProgress.handoff("Part 1", stream: @stream)
    mount = parent.mount("Part 1").follow_stream(@stream, part.key, poll: 0.05)
    (@closing ||= []) << parent
    TaskProgress.adopt(part.key, stream: @stream) { |root| root.subtask("Rows", total: 2) { |t| 2.times { t.tick! } } }
    wait_for { mount.task.done? }
    assert_equal ["Rows"], mount.task.subtasks.map(&:name)
  end

  def test_polling_answers_with_the_tree_and_then_with_not_modified
    root = TaskProgress.new("Polled")
    status, headers, body = TaskProgress::Poll.response(root)
    assert_equal 200, status
    batch = TaskProgress::Wire.parse(body.first)
    assert batch.reset?, "always the whole tree"
    status, = TaskProgress::Poll.response(root, {"HTTP_IF_NONE_MATCH" => headers["etag"]})
    assert_equal 304, status

    Thread.new {
      sleep 0.1
      root.subtask("News")
    }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    status, = TaskProgress::Poll.response(root, {"HTTP_IF_NONE_MATCH" => headers["etag"], "QUERY_STRING" => "wait=5"})
    assert_equal 200, status, "held until there was news"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  def test_polling_a_tree_another_process_writes
    import = TaskProgress.handoff("Importing", stream: @stream)
    TaskProgress.adopt(import.key, stream: @stream) { |root| root.subtask("Rows").done! }
    _, _, body = TaskProgress::Poll.response(TaskProgress.fetch(import.key, stream: @stream))
    state = fold_batches([TaskProgress::Wire.parse(body.first)])
    assert_equal ["Importing", "Rows"], state.each.map { |_, node| node.name }
  end
end

class MemoryStreamTest < Minitest::Test
  include StreamBehaviour

  def setup
    @stream = TaskProgress::MemoryStream.new
  end

  def test_the_default_stream_is_one_in_this_process
    assert_kind_of TaskProgress::MemoryStream, TaskProgress.stream
    import = TaskProgress.handoff("Defaulted")
    assert_equal "Defaulted", TaskProgress.fetch(import.key).name
  end

  def test_nothing_handed_off_cannot_be_adopted
    assert_raises(ArgumentError) { TaskProgress.adopt("task_progress:{nothing}", stream: @stream) }
    assert_raises(ArgumentError) { TaskProgress.adopt(TaskProgress.new("local"), stream: @stream) }
  end
end

class RedisStreamTest < Minitest::Test
  include StreamBehaviour

  def setup
    require "redis-client"
    client = RedisClient.config(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/15")).new_pool(size: 8)
    client.call("PING")
    @stream = TaskProgress::RedisStream.new(client)
  rescue LoadError, RedisClient::CannotConnectError
    skip "there is no Redis to talk to"
  end

  def test_redis_rb_works_too
    require "redis"
    stream = TaskProgress::RedisStream.new(Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/15")))
    key = "tp-test:#{rand(36**8).to_s(36)}"
    id = stream.append(key, "a")
    # A redis-rb client is one connection, which a waiting read holds - so the writer gets another
    Thread.new {
      sleep 0.05
      @stream.append(key, "b")
    }
    assert_equal ["b"], stream.read(key, after: id, timeout: 2).map(&:last)
  rescue LoadError
    skip "redis-rb is not installed"
  ensure
    stream&.delete(key) if key
  end
end

class WatchCommandTest < Minitest::Test
  def test_watching_a_tree_from_the_command_line
    require "redis-client"
    url = ENV.fetch("REDIS_URL", "redis://localhost:6379/15")
    stream = TaskProgress::RedisStream.new(RedisClient.config(url:).new_pool(size: 4))
    stream.get("ping")
    import = TaskProgress.handoff("Importing", stream:)
    reader, writer = IO.pipe
    pid = Process.spawn({"CI" => "1"}, RbConfig.ruby, File.expand_path("../exe/task_progress", __dir__), "watch", import.key, "--redis", url, err: writer)
    writer.close
    sleep 0.3
    TaskProgress.adopt(import.key, stream:) { |root| root.subtask("Rows", total: 2) { |t| 2.times { t.tick! } } }
    _, status = Process.wait2(pid)
    printed = reader.read
    assert status.success?, printed
    assert_includes printed, "✓ Importing", "even though it all came squashed into one batch"
  rescue LoadError, RedisClient::CannotConnectError
    skip "there is no Redis to talk to"
  end
end
