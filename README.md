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

```ruby
TaskProgress.cli("Import") do |root|
  download = root.subtask("Download", total: io.size, unit: "bytes")
  rows = root.subtask("Rows", total: rows.size, weight: 3)
  root.subtask("Wait for upstream", indeterminate: true) { |t| t.note("Connecting") }

  download.run { copy(download.track_io(io)) }
  rows.run { rows.each { import(it) && rows.tick! } }
end
```

On a terminal it redraws the tree in place. Piped, it prints one line per message. Spawned by a parent through `Mount#spawn`, it writes batches up the pipe instead.

## Tasks

- `subtask(name, total:, weight:, expect:, indeterminate:, unit:)`: with a block, the block is the task's work.
- `run { }`: done when the block returns, failed with the error when it raises (`Interrupt` included). The error is re-raised.
- `update_to(percent:, message:)`, `advance!(n)`, `tick!`, `note(message)`, `total=`.
- `done!`, `fail!(error_or_message, **flags)`.
- `transaction { }`: everything in the block lands as one batch, or nothing does.
- `track_io(io, total:, step:) { |io| }`: reading the IO advances the task by bytes. This works for `read`, line reads, `readpartial` and so `IO.copy_stream`, and seeks back do not count twice. The task moves in steps of 0.1% of the total, not once per read. It needs the optional `progressive_io` gem, and an IO with a position. For a pipe or a socket, call `advance!(chunk.bytesize)` instead.

A task reads 100% only once it and everything under it is done. Create a task's subtasks up front (or pass `expect:`) so its bar never jumps back when a new one opens.

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

`examples/web` has a Stimulus and a React renderer on a shared client (`task_tree.js`), which folds batches the same way the Ruby side does. A test holds the two to the same result. The terminal demo is `ruby -Ilib examples/cli_demo.rb`.

## The bench

`bin/dev` starts a bench on http://localhost:9292. Pick a scenario (worker threads, a wide or deep tree, transactions, a squashed relay, a lossy link that goes stale and recovers, a subprocess that fails, Ractors on Ruby 4) and watch it in both renderers side by side, with a stream inspector counting frames, resets, gaps and reconnects. You can cancel a job mid-run, cut the stream every N frames to watch it resume, or join a running job late.
