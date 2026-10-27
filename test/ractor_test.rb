require_relative "test_helper"

class RactorTest < Minitest::Test
  def setup
    skip "Ractors need Ruby 4.0 - on #{RUBY_VERSION} they crash the VM" unless TaskProgress::RACTORS
    @experimental = Warning[:experimental]
    Warning[:experimental] = false
  end

  def teardown
    Warning[:experimental] = @experimental unless @experimental.nil?
  end

  def test_a_tree_built_in_a_ractor_mounts_outside_it
    local = TaskProgress.new("local")
    mounts = 3.times.map { local.mount("ractor #{it}") }
    port = Ractor::Port.new

    ractors = mounts.each_index.map do |n|
      Ractor.new(port, n) do |port, n|
        root = TaskProgress.new("worker #{n}", outputs: [TaskProgress::Outputs::Ractor.new(port)])
        begin
          root.run do
            root.subtask("Crunch", total: 50) { |t| 50.times { t.tick! } }
            root.subtask("Fail") { raise "nope" }
          end
        rescue RuntimeError
          nil
        end
      ensure
        port.send([:finished, n]) # even when it dies, or the loop below waits forever
      end
    end

    finished = 0
    by_log = {}
    while finished < ractors.length
      message = port.receive
      if message.is_a?(Array) && message.first == :finished
        finished += 1
      else
        by_log[message.log] ||= mounts[by_log.size]
        assert_equal :applied, by_log[message.log] << message
      end
    end
    ractors.each(&:join)

    mounts.each do |mount|
      assert_equal :failed, mount.task.status
      assert_equal [["Crunch", :done, 50], ["Fail", :failed, 0]], mount.task.subtasks.map { [it.name, it.status, it.count] }
    end
  end

  def test_batches_cross_as_deep_frozen_copies
    batch = TaskProgress::Batch.new(log: +"x", prev: 0, seq: 1, at: 0.0, events: [TaskProgress::Event.new(path: [], op: :open, value: {name: +"n"})])
    sink = Object.new
    def sink.send(value) = @sent = value
    def sink.sent = @sent
    TaskProgress::Outputs::Ractor.new(sink).call(batch, nil)
    assert Ractor.shareable?(sink.sent)
    refute batch.events.first.value.frozen?, "the original is left alone"
  end
end

class RactorGateTest < Minitest::Test
  def test_ractor_output_refuses_to_run_before_ruby_4
    skip "on Ruby #{RUBY_VERSION} Ractors are supported" if TaskProgress::RACTORS
    error = assert_raises(NotImplementedError) { TaskProgress::Outputs::Ractor.new(Object.new) }
    assert_match(/Ruby 4\.0/, error.message)
  end
end
