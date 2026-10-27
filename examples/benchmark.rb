# How fast, and how big: `bundle exec ruby examples/benchmark.rb`. The MANUAL quotes what it
# printed on an M-series Mac - run it again before quoting anything new
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "task_progress"

def measure(label, count, unit = "ops")
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  puts format("%-52s %10.0f %s/s  (%.2fs)", label, count / seconds, unit, seconds)
end

def rss_kb = `ps -o rss= -p #{Process.pid}`.to_i

N = 200_000

root = TaskProgress.new("bench")
task = root.subtask("ticks", total: N)
measure("tick, no outputs", N) { N.times { task.tick } }

root = TaskProgress.new("bench", outputs: [TaskProgress::BufferedOutput.new(->(_, _) {})])
task = root.subtask("ticks", total: N)
measure("tick, through a BufferedOutput", N) { N.times { task.tick } }

stream_store = TaskProgress::MemoryStreamStore.new
import = TaskProgress.handoff("bench", stream_store:)
adopted = TaskProgress.adopt(import.key, stream_store:)
task = adopted.subtask("ticks", total: N)
measure("tick, adopted, to a MemoryStreamStore", N) { N.times { task.tick } }
adopted.log.close
puts format("%-52s %10d entries left after trimming", "", stream_store.read(import.key).length)

root = TaskProgress.new("bench")
tasks = 4.times.map { root.subtask("t#{it}", total: N / 4) }
measure("tick, 4 threads on one tree", N) { tasks.map { |t| Thread.new { (N / 4).times { t.tick } } }.each(&:join) }

GC.start
before = rss_kb
big = TaskProgress.new("big")
parent = big.subtask("files", expect: 100_000)
measure("subtask, 100,000 under one parent", 100_000) { 100_000.times { parent.subtask("file #{it}") } }
GC.start
puts format("%-52s %10.0f bytes/task", "memory per task", (rss_kb - before) * 1024.0 / 100_000)

snapshot = big.log.snapshot
measure("squash 100,000 tasks", 1, "squashes") { big.log.squashed }
measure("rows of 100,000 siblings, folded", 1, "draws") { snapshot.rows.to_a }
measure("HTMLRenderer, 100,000 siblings", 1, "draws") { TaskProgress::HTMLRenderer.new(id: "t").render(snapshot) }
