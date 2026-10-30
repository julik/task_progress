# frozen_string_literal: true

require "rbconfig"

# A pretend import that exercises most of what a tree can hold: a counted download, workers
# updating one tree from threads, a task with no measure, an engine in a subprocess mounted
# under its own node, and - when asked - a step that fails
module DemoJob
  CHILD = File.expand_path("child_worker.rb", __dir__)

  def self.run(root, fail: false, speed: 1.0)
    nap = ->(seconds) { sleep(seconds / speed) }
    # Made up front, so the root's denominator is fixed and its bar never jumps back
    download = root.subtask("Download catalogue", total: 12 * 1024 * 1024, unit: "bytes", cancelable: true)
    parse = root.subtask("Parse records", weight: 2)
    wait = root.subtask("Wait for upstream", indeterminate: true, cancelable: true)
    # Canceling the mount asks the subprocess to stop; what runs inside it cannot be called off from here
    engine = root.mount("Engine (subprocess)", weight: 3, cancelable: true)
    publish = root.subtask("Publish")

    download.run { 24.times { download.advance(512 * 1024) && nap.call(0.04) } }

    parse.run do
      workers = 4.times.map { |n| parse.subtask("worker #{n + 1}", total: 40, cancelable: true) }
      workers.map do |worker|
        Thread.new { worker.run { 40.times { |i| worker.tick(message: "record #{i + 1}") && nap.call(rand(0.01..0.05)) } } }
      end.each(&:join)
    end

    wait.run { ["Connecting", "Negotiating", "Waiting in queue"].each { wait.note(it) && nap.call(0.5) } }

    engine.pipes do |pipes|
      pid = Process.spawn(pipes.env, RbConfig.ruby, CHILD, "--speed", speed.to_s, *("--fail" if fail), err: File::NULL, **pipes.redirects)
      pipes.follow
    ensure
      Process.wait(pid) if pid
    end
    raise "the engine failed: #{engine.task.error&.dig(:message)}" if engine.task.failed?

    publish.run { publish.update(50, message: "Almost there") && nap.call(0.3) }
    root
  end
end
