require_relative "test_helper"
require "open3"
require "tmpdir"

# The browser client must agree with State on every percent, or the bars in the demos lie
class JsParityTest < Minitest::Test
  include TestHelpers

  SCRIPT = File.expand_path("../examples/web/test/parity.mjs", __dir__)

  def setup
    skip "node is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
  end

  def test_the_browser_client_folds_to_the_same_percents
    10.times do |seed|
      rng = Random.new(seed)
      io = StringIO.new
      root = TaskProgress.new("root", outputs: [TaskProgress::Outputs::NDJSON.new(io)], expect: rng.rand(0..2))
      live = [root]
      300.times do
        task = live.sample(random: rng)
        case rng.rand(8)
        when 0, 1 then live << task.subtask("t", total: [nil, rng.rand(1..9)].sample(random: rng), weight: [nil, rng.rand(1..3)].sample(random: rng),
          expect: [nil, 3].sample(random: rng), indeterminate: rng.rand(6).zero?)
        when 2 then task.update_to(percent: rng.rand(0..99) + [0, 0.5].sample(random: rng))
        when 3 then task.advance!(rng.rand(1..3))
        when 4 then task.done!
        when 5 then task.fail!("x")
        when 6 then task.note("n")
        when 7 then root.log.append(TaskProgress::Event.new(path: task.path, op: :prune)) && live.select! { root.log.snapshot.key?(it.path) }
        end
      rescue ArgumentError
        nil
      end

      js = Dir.mktmpdir do |dir|
        File.write(File.join(dir, "batches.ndjson"), io.string)
        out, err, status = Open3.capture3("node", SCRIPT, File.join(dir, "batches.ndjson"))
        assert status.success?, err
        JSON.parse(out)
      end
      snapshot = root.log.snapshot
      ruby = snapshot.each.map { |path, node| [path, node.name, node.status.to_s, snapshot.percent(path)] }
      assert_equal root.log.seq, js["seq"]
      assert_equal ruby, js["rows"], "seed #{seed}"
    end
  end
end
