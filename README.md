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
- `done!`, `fail!(error_or_message, **flags)`, `cancel!(reason)`. Each ends what is still open under the task too: `done!` with a `done`, `fail!` and `cancel!` with a `cancel` - those tasks did not fail, they were cut short.
- Canceling works from any thread. Whoever touches a canceled task next gets a `TaskProgress::Canceled`, which `run` takes as the end of that task's work, so the worker stops at its next tick. Ctrl-C in a `run` block cancels rather than fails.
- `on_cancel { |reason| }`: for work that blocks, and would not touch its task until it unblocks - close the connection it waits on, raise into its thread. Called at once if the task already was canceled.

## Canceling from outside

A task with `cancelable: true` may be offered for canceling; the renderers in `js/` show it a cancel button. A request names a task by its path and only asks - the tree that owns the task decides, and its answer is the `cancel` event coming back up the stream:

```ruby
root.request_cancel(path, "From the browser")  # => :canceled, :forwarded, :moot or :refused
```

It decides in one transaction against the tree as it stands, so it cannot race the task finishing. A task that already ended, or is gone, is `:moot` - a request that comes too late is not an error. One under a mount is `:forwarded` down the child's control pipe, mount by mount, and the child decides in turn.

Over HTTP, sign the right to cancel. `TaskProgress::CancelToken` issues an expiring HMAC token for a log, for the page that shows the tree, and verifies it when a cancellation comes back:

```ruby
tokens = TaskProgress::CancelToken.new(ENV.fetch("TASK_PROGRESS_SECRET"))
tokens.issue(root.log.id, expires_in: 3600)        # into the page, next to the stream URL
tokens.verify(params[:token]) == root.log.id       # when POST .../cancellations comes in
```

The bench shows it as a resource: `POST /jobs/:id/cancellations` creates the cancellation of one task, asking again gives back the same one, and its state settles to `canceled` or `moot`.

## Writing work that can be canceled

A cancel never stops a thread from the outside. It marks the task canceled, and the work stops when it next notices. Most work notices on its own; the rest needs a line or two.

**Work that reports as it goes needs nothing.** The next `tick!`, `advance!` or `note` on a canceled task raises `TaskProgress::Canceled`. `run`, and so a `subtask` block, takes that as the end of that task's work: the task is canceled rather than failed, and the code after the block carries on.

```ruby
root.subtask("Rows", total: rows.size, cancelable: true) do |t|
  rows.each { import(it) && t.tick! }
end
root.subtask("Publish") { publish! }  # still runs if Rows was canceled
```

**Clean up in `ensure`, or rescue `Canceled` for what only a cancel should undo.** It is an exception, so `ensure` runs as usual. Re-raise it, so `run` sees it:

```ruby
root.subtask("Export", cancelable: true) do |t|
  File.open(tmp, "w") { |f| rows.each { f.puts(it) && t.tick! } }
rescue TaskProgress::Canceled
  File.delete(tmp)  # no half-written export
  raise
end
```

**Work that reports rarely can ask.** `canceled?` reads the tree without raising:

```ruby
poll.run { sleep(1) until poll.canceled? || ready? }
```

**Work that blocks needs unblocking.** A call that waits - an HTTP request, a socket read, a queue - will not touch its task until it returns. Give it an `on_cancel` that ends the wait. Whatever the call raises as it unblocks is taken as the cancel working, not as a failure:

```ruby
fetch.run do |t|
  http = Net::HTTP.start(host)
  t.on_cancel { http.finish }  # the request in flight raises, and the task ends as canceled
  http.get(path)
end
```

For a wait nothing can interrupt, raise into the thread instead: `me = Thread.current; t.on_cancel { me.raise(TaskProgress::Canceled.new(t)) }`. `on_cancel` runs on whichever thread canceled the task, so keep it to ending the wait.

**Do not swallow it.** `Canceled` is an `Exception`, like `Interrupt`, so `rescue => e` lets it through. Code that rescues `Exception` should re-raise `TaskProgress::Canceled`.

**Threads and child processes follow.** Canceling a task cancels everything still open under it, so workers on threads of their own each stop at their next tick. A child process started with `Mount#spawn` gets the request over its control pipe, and the same patterns apply inside it. A child too stuck to notice is sent TERM after the mount's `grace:`, which Ruby raises inside the work like any other exception.

**Afterwards, `canceled?` tells what happened.** `run` returns `nil` for a task that was canceled, so code that needs the result can check:

```ruby
report = root.subtask("Report", cancelable: true) { |t| build_report(t) }
mail(report) unless root.subtasks.last.canceled?
```
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

The remote tree is grafted under the mount node by prefixing its paths, and only the mount writes under that node. A second pipe carries cancel requests down to the child, which `cli` reads; canceling the mount asks the child to cancel its root, and sends it TERM if it is still running after `grace:` seconds. Anything the remote sends is distrusted, and a batch that does not apply is dropped whole. For a Ractor, give its tree an `Outputs::Ractor.new(port)` with a `Ractor::Port`, and feed what arrives to `mount << port.receive`.

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
requestCancel("/jobs/42/cancellations", path, { token })              // creates a signed cancellation
```

The terminal demo is `ruby -Ilib examples/cli_demo.rb`.

## The bench

`bin/dev` starts a bench on http://localhost:9292. Pick a scenario (worker threads, a wide or deep tree, transactions, a squashed relay, a lossy link that goes stale and recovers, a subprocess that fails, Ractors on Ruby 4) and watch it in both renderers side by side, with a stream inspector counting frames, resets, gaps and reconnects. You can cancel a job mid-run, cut the stream every N frames to watch it resume, or join a running job late.
