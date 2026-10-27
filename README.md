# TaskProgress

Progress for task trees: in one process, across threads, Fibers, Ractors and subprocesses, and out to a terminal or a browser.

Think progress bars, but properly, for complex task trees that the user needs to be updated on. Fit for both the web and the CLI.

The progress is not a mutable structure but an _event log_ which allows task progress collection to be distributed. Every change goes through one lock, which numbers it and commits it as a batch. Outputs receive the batches in order: a terminal renderer, a pipe, an SSE stream, a Sossego stream. A batch is one transaction. On a pipe it is one line, in a stream one event or row, so a reader gets all of it or none of it.

Any run of batches can be squashed into one, and a reader that joins late starts from that squash. This also lends itself perfectly to redraw-the-world UIs like React - but using it with Stimulus is a breeze as well.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/bench-dark.png">
  <img alt="The bench (bin/dev) mid-job: an import with worker threads and an engine subprocess mounted under its own node, drawn by the Stimulus and React renderers side by side above the stream inspector" src="docs/bench-light.png">
</picture>

## On the command line

A bar, the way it always worked:

```ruby
bar = TaskProgress.bar("Importing", total: rows.size)
rows.each { import(it) && bar.tick! }
```

Or over a collection, which takes its total from `size`:

```ruby
TaskProgress.iterate(rows, "Importing") { |row| import(row) }
```

```
⠹ Importing  ██████████░░░░░░░░░░ 21/40  19/s  ETA 1.0s  1.1s
```

The bar finishes once its count reaches the total. `bar.puts("Skipped row 12")` prints a line above it that stays. With `using TaskProgress::Refinements`, `rows.each.with_progress("Importing") { }` works too.

For a tree of tasks:

```ruby
TaskProgress.cli("Import") do |root|
  download = root.subtask("Download", total: io.size, unit: "bytes")
  rows = root.subtask("Rows", total: rows.size, weight: 3)
  root.subtask("Wait for upstream", indeterminate: true) { |t| t.note("Connecting") }

  download.run { copy(download.track_io(io)) }
  rows.run { rows.each { import(it) && rows.tick! } }
end
```

On a terminal it redraws the tree in place. Piped, or on CI, it writes an execution log instead - finished lines, never a redraw:

```
[ 31%   3.0s] Import › Rows: row 119
[ 62%   6.0s] Import › Rows: row 245
[100%   9.7s] ✓ Import › Rows  9.7s
[ 67%  10.2s] ✗ Import › Engine: watermarking failed
```

Finishing, failing and `puts` lines go out every time; notes and counts at most once every 3 seconds, the newest. After a minute with nothing to say it says it is still going, so a CI runner does not take a long step for a hang. Spawned by a parent through `Mount#spawn`, it writes batches up the pipe instead.

## Tasks

- `subtask(name, total:, weight:, expect:, indeterminate:, unit:)`: with a block, the block is the task's work.
- `run { }`: done when the block returns, failed with the error when it raises (`Interrupt` included). The error is re-raised.
- `update_to(percent:, message:)`, `advance!(n)`, `tick!`, `note(message)`, `total=`.
- `done!`, `fail!(error_or_message, **flags)`.
- `iterate(collection, name, total:, step:) { |item| }`: a subtask that advances once per item and finishes with the loop. Without a block, an Enumerator.
- `puts(message)`: a line printed above the tree. The tree does not keep it, so a reader joining later does not see it.
- A counted task is done once its count reaches its total; pass `autofinish: false` when the total is only a guess. `done!` also finishes every task still open under it.
- `transaction { }`: everything in the block lands as one batch, or nothing does.
- `track_io(io, total:, step:) { |io| }`: reading the IO advances the task by bytes. This works for `read`, line reads, `readpartial` and so `IO.copy_stream`, and seeks back do not count twice. The task moves in steps of 0.1% of the total, not once per read. It needs the optional `progressive_io` gem, and an IO with a position. For a pipe or a socket, call `advance!(chunk.bytesize)` instead.

A task reads 100% only once it and everything under it is done, each by a `done!` of its own: children that are all through do not finish their parent. `run`, `cli`, `iterate` and a mount do this for you. Create a task's subtasks up front (or pass `expect:`) so its bar never jumps back when a new one opens.

## Another process, another Ractor

```ruby
engine = root.mount("Engine", weight: 3)
engine.spawn(RbConfig.ruby, "engine.rb")  # the child uses TaskProgress.cli
```

The remote tree is grafted under the mount node by prefixing its paths, and only the mount writes under that node. Anything the remote sends is distrusted, and a batch that does not apply is dropped whole. For a Ractor, give its tree an `Outputs::Ractor.new(port)` with a `Ractor::Port`, and feed what arrives to `mount << port.receive`.

Ractors need Ruby 4.0. On 3.4 they corrupt the VM (a `super` into a C constructor while Ractors run brings the process down, sometimes minutes later), so `Outputs::Ractor` refuses to start there. Everything else runs on 3.4.

## To a browser

```ruby
[200, TaskProgress::SSE::HEADERS, TaskProgress::SSE.new(root)]      # Rack
root.add_output(TaskProgress::Outputs::Publish.new(sossego_stream))  # a job elsewhere
```

Any task can be streamed on its own: `SSE.new(upload)` or `upload.add_output(output)` sends just that subtree, with `upload` as its root - first squashed, then live. Batches elsewhere in the tree are left out, and the branch numbers its batches itself, so a reader sees no gaps. Feed it to a Mount and the subtree is grafted back whole.

The browser client ships with the gem, in `js/` (`TaskProgress.js_path`): `task_tree.js` folds batches the same way the Ruby side does, and a test holds the two to the same result. `render_queue.js` draws at most once a frame, however fast batches come. There is a Stimulus controller and a React component on top, and `task_tree.css` for their rows. Nothing to build - serve the directory under any prefix, for example with [Assiette](https://github.com/julik/assiette):

```ruby
use Assiette::Server, root: "public", additional_directory_mappings: {"/task_progress" => TaskProgress.js_path}
```

```js
import { followEventSourceAt, followBatches, applyBatchTo, TaskTree } from "/task_progress/task_tree.js"

followEventSourceAt("/jobs/42/events", (tree, changes) => draw(tree))  // an SSE stream, drawn once a frame
const feed = followBatches((tree) => draw(tree))                       // batches from anywhere: feed.push(batch)
applyBatchTo(batch, tree)                                              // one batch, folded in place
```

The terminal demo is `ruby -Ilib examples/cli_demo.rb`.

## The bench

`bin/dev` starts a bench on http://localhost:9292. Pick a scenario (worker threads, a wide or deep tree, transactions, a squashed relay, a lossy link that goes stale and recovers, a subprocess that fails, Ractors on Ruby 4) and watch it in both renderers side by side, with a stream inspector counting frames, resets, gaps and reconnects. You can cancel a job mid-run, cut the stream every N frames to watch it resume, or join a running job late.
