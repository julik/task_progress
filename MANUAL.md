# TaskProgress manual

Everything TaskProgress does, and how. The [README](README.md) is the short version.

- [How it works](#how-it-works)
- [Tasks](#tasks)
- [How far along a task is](#how-far-along-a-task-is)
- [Finishing](#finishing)
- [Bars, loops and IO](#bars-loops-and-io)
- [On the command line](#on-the-command-line)
- [Outputs](#outputs)
- [Streaming a branch](#streaming-a-branch)
- [Other processes and Ractors](#other-processes-and-ractors)
- [Canceling](#canceling)
- [Writing work that can be canceled](#writing-work-that-can-be-canceled)
- [Canceling from outside](#canceling-from-outside)
- [Server-Sent Events](#server-sent-events)
- [The browser client](#the-browser-client)
- [The wire format](#the-wire-format)
- [Testing](#testing)
- [The bench](#the-bench)

## How it works

A tree of tasks lives in a **log**. Nothing in the tree is changed directly: every change is an **event**, and events are committed in **batches** - one batch per transaction, numbered by `seq`, each naming the one before it in `prev`. The log holds one lock, so changes from any number of threads land in one order.

The tree as it stands is what you get by folding every batch, in order. A batch with `prev` 0 starts over from nothing, which is how a **squash** announces itself: the whole tree so far as one batch, which is what a reader that joins late starts from. Folding the squash gives back the same tree.

**Outputs** get every batch, in order, outside the lock - so a slow output never holds up a worker that is waiting for the lock, though it does hold up whoever committed (wrap it in `BufferedOutput` if that matters). A terminal redraw, a pipe to a parent process, an SSE stream to a browser and a Sossego stream are all outputs.

A task is named by its **path** from the root: `[]` is the root, `["x3k0", "00af"]` a child of the root's child `x3k0`. Each id is four random base36 characters, unique among its siblings, and never reused within a log - so a path is a sound key for a React row, and a pruned task's path never turns up on another one. A handle (`TaskProgress`) is just a log and a path: cheap to make, and equal to any other handle for the same task.

Timestamps are for display only. Order is `seq`, `prev`, the order of events in a batch, and the order children were opened in.

## Tasks

```ruby
root = TaskProgress.new("Import")                     # a tree with no outputs
root = TaskProgress.new("Import", outputs: [output])  # see Outputs
root = TaskProgress.new("Import") { |percent:, message:| job.update!(percent:, message:) }  # a Summary
```

`TaskProgress.null` is a silent root, for a library's default.

### Opening tasks

```ruby
task = root.subtask("Rows", total: 120)
```

| Option | |
|---|---|
| `total:` | Counted: driven with `advance!`/`tick!`, reads `count / total`. |
| `weight:` | How much of the parent it is; 1 by default. |
| `expect:` | How many children it will have. Those not opened yet count as zero, so the bar does not jump back when they open. |
| `indeterminate:` | No measure of its own: counts as zero until done, and draws as a spinner or a sliding bar. |
| `unit:` | `"bytes"` makes counts read as `12 MB / 40 MB`. |
| `cancelable:` | May be offered for canceling - see [Canceling from outside](#canceling-from-outside). |
| `autofinish:` | `false` stops a counted task finishing at its total - see [Finishing](#finishing). |

With a block, `subtask` runs the block as the task's work and returns its value (see `run`).

### Changing them

| | |
|---|---|
| `update_to(percent:, message:)` | Sets the percent of an uncounted task. 100 finishes it. |
| `advance!(n = 1, message:)`, `tick!(message:)` | Adds to the count. |
| `note(message)` | The latest thing it says, shown on its row. |
| `puts(message)` | A line printed above the tree, which stays. The tree does not keep it - see [Outputs](#outputs). |
| `total=`, `name=` | |
| `done!(message)`, `fail!(error, **extra)`, `cancel!(reason)` | See [Finishing](#finishing) and [Canceling](#canceling). |
| `transaction { }` | Everything in the block lands as one batch, or none of it does. |

`fail!` takes an exception, a message, or nothing. An exception keeps its class, message, backtrace and up to three causes. `extra` goes along with the error: booleans and integers only, a reader drops the rest.

Anything that starts work - a percent, a count, a note, finishing - starts the task and every task above it. A pending task only becomes active when something happens to it.

### Reading them

`name`, `status` (`:pending`, `:active`, `:done`, `:failed`, `:canceled`), `percent`, `fraction` (unrounded, 0..1), `count`, `total`, `message`, `error`, `done?`, `failed?`, `canceled?`, `finished?`, `cancelable?`, `parent`, `root`, `subtasks`, `find(path)` and `node` (the whole record, frozen). Reads come from a frozen snapshot, so they are safe from any thread.

`find` takes a path under this task, as an Array of ids or as the ids joined with `"/"` - the way the browser client keys its rows.

### Transactions

```ruby
root.transaction do
  current.done!
  following.update_to(percent: 0, message: "Starting")
end
```

Readers see both changes or neither, never a frame with nothing running in between. A transaction opened inside another one on the same Fiber joins it. A block that raises rolls back everything it did. The block holds the log's lock throughout: keep it short, and never wait in it on another thread that writes to the same log.

## How far along a task is

- A task with children is the weighted mean of its children; children it was told to `expect` and has not opened yet count as zero.
- A counted task without children is `count / total`.
- An indeterminate one counts as zero until it is done.
- Anything else goes by its percent.
- A task reads 100% only once it is **complete**: done itself, and everything under it ended. Until then it is held at 99, so a task that is 99.6% of the way never rounds up to look finished.

A task whose children all finished is not complete until it is done itself - it may have more to do after them. A failed or canceled child does not hold back a parent that went on to finish regardless.

## Finishing

Every task finishes by an event of its own - `done`, `fail` or `cancel`. You rarely send them by hand:

- A **block** (`subtask { }`, `run { }`, `cli { }`) is done when it returns, failed with the error when it raises, and canceled on Ctrl-C.
- A **counted task** is done once its count reaches its total. Pass `autofinish: false` when the total is a guess and the work may run past it. Ticks past an automatic finish are ignored.
- **`done!`** finishes the task and every task still open under it, each with a `done` of its own, deepest first, in one batch. A mounted subtree is left to its remote.
- **`fail!`** cancels what is still open under the task - those tasks did not fail, they were cut short.
- **`bar`, and `cli` without a block,** are finished when the program exits: done if it ends well, failed with the error if it is going down with one.
- A **mount** is finished by its remote, or by the parent - see [Other processes](#other-processes-and-ractors).

Finishing a finished task does nothing. Anything else on one raises.

## Bars, loops and IO

```ruby
bar = TaskProgress.bar("Importing", total: rows.size)  # one bar, no block; finishes at its total
bar = TaskProgress.bar("Streaming")                    # no total: counts and spins
```

`bar` takes `io:` (`$stderr` by default) and `quiet:`, and picks its output like `cli` does.

### iterate

```ruby
TaskProgress.iterate(rows, "Importing") { |row| import(row) }  # a bar over a collection
root.iterate(files, "Files") { |file| copy(file) }             # a subtask
root.iterate(rows, "Rows").map { transform(it) }               # without a block, an Enumerator
root.iterate(downloader, "Download", total: bytes, step: CHUNK)
```

The total comes from `size`, never `count` - so a lazy enumerator stays lazy, and one with no size just counts. The task is done when the loop ends and failed with the error if the block raises. It advances in steps of a thousandth of the total, not once per item, so a loop over cheap items is not held up by its own progress. With `using TaskProgress::Refinements`, any Enumerable has `with_progress(name)`, in the files that ask for it.

### track_io

```ruby
download.run { IO.copy_stream(download.track_io(file), dest) }
download.track_io(file) { |io| ZipKit::FileReader.read_zip_structure(io: io) }  # done when the block returns
```

Reading the IO advances the task by bytes: `read`, line reads, `readpartial` and so `IO.copy_stream`. Readers seek - ZipKit reads the end of an archive first - so only the furthest position counts. It moves in steps of 0.1% of the total. It needs the optional `progressive_io` gem and an IO with a position; for a pipe or a socket, `advance!(chunk.bytesize)` as you go.

## On the command line

```ruby
TaskProgress.cli("Import") { |root| ... }  # the block is the root's work
root = TaskProgress.cli("Import")          # or not: then finished at exit
```

`cli` picks its output from where it runs:

- **Spawned by `Mount#spawn`** (`TASK_PROGRESS_FD` is set): batches up the pipe, and cancel requests read from the control pipe.
- **On a terminal**: `TerminalOutput`.
- **Piped, or on a terminal with `CI` set**: `ExecutionLogOutput`.
- **`quiet: true`**: nothing.

### Terminal

Redraws the tree in place from a ticker thread of its own, ten times a second, so spinners turn while nothing reports. A finished subtree folds into its one line; under a finished node only what failed shows, so a failure leaves the way down to it. When the tree is taller than the screen, finished lines are left out first, then the ones not started. Counted tasks show their rate and time left. When the root finishes the tree is drawn one last time and left on screen, or erased with `erase: true`. Lines a task `puts` go above the tree and stay.

### Execution log

For a CI log, or anything read top to bottom after the fact: one finished line per thing worth saying, never a redraw, each led by the overall percent and the time since the root opened.

```
[ 31%   3.0s] Import › Rows: row 119
[100%   9.7s] ✓ Import › Rows  9.7s
[ 67%  10.2s] ✗ Import › Engine: watermarking failed
[ 70%  10.3s] ⊘ Import › Publish: Ctrl-C
```

Finishing, failing, canceling and `puts` lines go out at once, every time - though of a task and the ones under it ending in one batch, only the task says so. Notes and counts are only ever the latest news, so at most one of those goes out per `interval` (3 seconds), the newest. After `heartbeat` (60 seconds) with nothing to say it says it is still going, so a CI runner does not take a long quiet step for a hang.

## Outputs

An output is anything with `call(batch, log)`. It gets every batch the log commits, in order, outside the lock, and may read `log.snapshot` for the tree as it now stands.

```ruby
root.add_output(output)                  # the tree so far as one squashed batch, then every batch after it
root.add_output(output, replay: false)   # only what comes next
root.add_output { |batch, log| ... }
root.remove_output(output)
```

An output that raises does not stop the others; `log.on_output_error = ->(error, output) { }` hears about it (it warns by default).

| Output | |
|---|---|
| `TerminalOutput.new(io, interval: 0.1, erase: false)` | The redrawn tree. `interval: nil` redraws on every batch, with no thread. |
| `ExecutionLogOutput.new(io, interval: 3, heartbeat: 60)` | Finished lines, for CI and pipes. |
| `SummaryOutput.new { \|percent:, message:\| }` | The root's percent and the latest thing said, called only when either changes. For a progress column in a database. |
| `NDJSONOutput.new(io)` | One batch per line, for a Mount at the other end of a pipe. |
| `PublishingOutput.new(stream, event_name: "task_progress")` | Each batch as a JSON-ready Hash to anything with `publish(name, payload)` - a Sossego stream. |
| `BufferedOutput.new(output, interval: 0.25)` | A thread between the log and a slow output. What piles up while it works goes out squashed into one batch: the prunes, then a put for every node touched. |
| `RactorOutput.new(port)` | Each batch as a deep frozen copy to a `Ractor::Port`. Ruby 4.0 only. |
| `TaskProgress::SSE` | Not an output but a Rack body - see [Server-Sent Events](#server-sent-events). |

`puts` lines travel as a `say` event, which changes nothing in the tree: a squash drops them, the way a terminal's scrollback is gone once a program exits. The terminal and the execution log print them; a mount and a buffer pass them on.

## Streaming a branch

```ruby
upload.add_output(output)
TaskProgress::SSE.new(upload)
root.log.squashed(upload.path)
```

Any task can be streamed as a tree of its own: the task becomes the root at `[]`, batches that do not touch it are left out, and the branch numbers its batches itself - its log id is the log's with the path appended - so a reader sees no gaps. That is a Mount run backwards: a Mount fed from a branch grafts it back whole. Pruning an ancestor ends the branch, with one last empty reset.

## Other processes and Ractors

```ruby
engine = root.mount("Engine", weight: 3, cancelable: true)
status = engine.spawn(RbConfig.ruby, "engine.rb", grace: 5)  # returns its Process::Status
```

A **mount** is a node whose subtree is fed from elsewhere. The remote's root lands on the mount node and its `["x3k0"]` on `[*mount, "x3k0"]` - mounting is prefixing, and a relay through several processes prefixes once per hop. The mount node is sealed: only its Mount writes under it, and the remote cannot rename or reweigh it. Each remote batch is committed here as one batch, or dropped whole if it does not apply. The remote's times are moved onto this clock by the gap between its commit time and ours.

```ruby
mount << batch     # a Batch, its Hash form, or a line of NDJSON
# => :applied, :duplicate, :gap or :rejected
mount.follow(io)   # reads NDJSON until EOF
mount.stale?
```

A batch already applied is a duplicate - ordinary after a reconnect. One that does not follow the last is a gap: the subtree is marked stale, and stays so until a batch with `prev` 0 replaces it whole. Anything the remote sends is distrusted (see [The wire format](#the-wire-format)).

### Spawn

`spawn` starts a command with `TASK_PROGRESS_FD=3` pointing at a pipe it follows, and `TASK_PROGRESS_CONTROL_FD=4` pointing at one it writes cancel requests to. The child uses `TaskProgress.cli`, which finds both; neither pipe is handed down to processes the child starts. Its stdout and stderr stay its own.

- A child that exits without finishing its root fails the mount. One that exits with an error fails it with that.
- Canceling the mount asks the child to cancel its root, and sends TERM if it is still running `grace` seconds later. The pid is only ever signaled while it is still ours.
- Interrupted (Ctrl-C, a timeout), `spawn` terminates the child at once and cancels or fails the mount.
- The parent may end the mount itself, when the remote went away: `mount.done!`, `fail!`, `cancel!`. Whatever the remote sends after that changes nothing.

### Ractors

```ruby
port = Ractor::Port.new
Ractor.new(port) do |port|
  root = TaskProgress.new("worker", outputs: [TaskProgress::RactorOutput.new(port)])
  ...
end
mount << port.receive
```

Ractors need Ruby 4.0. On 3.4 they corrupt the VM - a `super` into a C constructor while Ractors run brings the process down, sometimes minutes later - so `RactorOutput` refuses to start there. Everything else runs on 3.4.

## Canceling

```ruby
task.cancel!("Not needed")
task.canceled?
```

`cancel!` cancels the task and every task still open under it, each with a `cancel` of its own carrying the reason, in one batch, from any thread. Calling off a task that never began does not begin it. Canceling reaches into mounts: a mount canceled from here asks its child to stop.

A cancel never stops a thread from outside. It marks the task canceled, and the work stops when it next notices: whoever touches a canceled task next - a tick, a note, opening a subtask - gets a `TaskProgress::Canceled`. `run` takes that as the end of that task's work and returns `nil`; the code after it carries on. A task further up being canceled stops the work in between as well.

`Canceled` is an `Exception`, like `Interrupt`, so a `rescue => e` around one step cannot swallow it and carry on with the next. Ctrl-C (`Interrupt`) in a `run` block cancels rather than fails.

```ruby
task.on_cancel { |reason| ... }
```

Calls the block once the task is canceled - at once, if it already was. A task that ends any other way drops it. It runs on whichever thread delivers the cancel, after it was committed: keep it short, and let it unblock the work rather than do the work. One that raises does not stop the others.

## Writing work that can be canceled

Most work notices a cancel on its own; the rest needs a line or two.

**Work that reports as it goes needs nothing.**

```ruby
root.subtask("Rows", total: rows.size, cancelable: true) do |t|
  rows.each { import(it) && t.tick! }
end
root.subtask("Publish") { publish! }  # still runs if Rows was canceled
```

**Clean up in `ensure`, or rescue `Canceled` for what only a cancel should undo.** Re-raise it, so `run` sees it:

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

**Work that blocks needs unblocking.** A call that waits - an HTTP request, a socket read, a queue - will not touch its task until it returns. Give it an `on_cancel` that ends the wait. Once a task is canceled, whatever its work raises as it unwinds is taken as the cancel working, not as a failure:

```ruby
fetch.run do |t|
  http = Net::HTTP.start(host)
  t.on_cancel { http.finish }  # the request in flight raises, and the task ends as canceled
  http.get(path)
end
```

For a wait nothing can interrupt, raise into the thread: `me = Thread.current; t.on_cancel { me.raise(TaskProgress::Canceled.new(t)) }`.

**Do not swallow it.** Code that rescues `Exception` should re-raise `TaskProgress::Canceled`.

**Threads and child processes follow.** Workers on threads of their own each stop at their next tick. A child process gets the request over its control pipe, and the same patterns apply inside it. A child too stuck to notice is sent TERM after the mount's `grace`, which Ruby raises inside the work like any other exception.

**Afterwards, `canceled?` tells what happened**, since `run` returns `nil` for a canceled task:

```ruby
report = root.subtask("Report", cancelable: true) { |t| build_report(t) }
mail(report) unless root.subtasks.last.canceled?
```

## Canceling from outside

A browser, or a parent process, can only *ask*. The tree that owns the task decides, and its answer is the `cancel` event coming back up the stream - nothing waits for a reply.

```ruby
root.request_cancel(path, "From the browser")
```

| Returns | |
|---|---|
| `:canceled` | It was, along with everything still open under it. |
| `:forwarded` | It lives in a mounted child, which was asked. Its cancel comes back up the stream, if it comes. |
| `:moot` | There is nothing left to cancel: no such task, or it has already ended, or the child it ran in has exited. |
| `:refused` | It is not `cancelable`. |

It decides in one transaction against the tree as it stands, so it cannot race the task finishing: the outcome is canceled or moot, never both. A request that comes too late is moot, not an error - by the time it arrives the task may well have finished and its process exited. A request for a task under a mount goes down that mount's control pipe, and on through nested mounts, each hop taking off its own prefix; the child decides in turn. When the parent asks for a child's root, the mount was ended there, so the child cancels its root whether it is cancelable or not.

`accept_cancel_requests(io)` reads requests off any IO, one JSON line each (`{"cancel": [ids], "reason": "..."}`), on a thread of its own. `cli` uses it for the control pipe.

### Over HTTP

Only `cancelable` tasks can be asked for. Sign the right to ask, so a cancel cannot be forged or replayed:

```ruby
tokens = TaskProgress::CancelToken.new(ENV.fetch("TASK_PROGRESS_SECRET"))  # 32 bytes or more
token = tokens.issue(root.log.id, expires_in: 3600)  # into the page, next to the stream URL
tokens.verify(params[:token])                         # => the log id it was issued for, or nil
```

A token is an HMAC-SHA256 over a log id and an expiry, checked in constant time. It says the bearer may ask for tasks in that tree to be canceled; which tasks is for `cancelable` to say.

Treat a cancellation as a resource rather than a call. The bench does it like this:

```
POST /jobs/:id/cancellations    {"path": "x3k0/00af", "token": "..."}
  201  {"id": "x3k0.00af", "path": "x3k0/00af", "state": "canceled"}   Location: /jobs/:id/cancellations/x3k0.00af
  200  the same cancellation, when asked again
  403  no token, a mangled one, an expired one, or another job's
  409  the task is not cancelable
  422  a malformed path
GET  /jobs/:id/cancellations/:id
```

Its `state` is `canceled`, `requested` while a child process has been asked and has not answered down the stream yet, or `moot`. A moot request still gets a 201 - the job finished first, or is gone, and that is no error. See `examples/web/app.rb`.

## Server-Sent Events

```ruby
[200, TaskProgress::SSE::HEADERS, TaskProgress::SSE.new(task)]  # Rack
TaskProgress::SSE.response(task)                                 # the same

headers.merge!(TaskProgress::SSE::HEADERS)                       # Rails
self.response_body = TaskProgress::SSE.new(task)
```

First the tree so far, squashed into one batch with `prev` 0, then every batch as it commits - each in a `batch` event whose `id:` is its seq. A browser that reconnects starts over from a fresh squash, which is always right and costs a few puts. It pings every `heartbeat:` seconds (15) while nothing happens, and ends once the task it streams has finished. Given a subtask, it streams only that branch.

The tree must live in the serving process. For one that lives in a job elsewhere, have the job publish to a stream (`PublishingOutput`) and serve that.

## The browser client

Plain ES modules in `js/`, shipped with the gem: `TaskProgress.js_path`. Serve the directory under any prefix - imports inside it are relative. With [Assiette](https://github.com/julik/assiette):

```ruby
use Assiette::Server, root: "public", additional_directory_mappings: {"/task_progress" => TaskProgress.js_path}
```

The Stimulus controller and the React component import `@hotwired/stimulus`, `react`, `react-dom/client` and `htm` by bare name, so the page's import map provides them.

### task_tree.js

```js
import { followEventSourceAt, followBatches, applyBatchTo, requestCancel, TaskTree } from "/task_progress/task_tree.js"

const following = followEventSourceAt("/jobs/42/progress", (tree, changes) => draw(tree))
following.close()

const feed = followBatches((tree, changes) => draw(tree))  // for batches from anywhere: a WebSocket, ActionCable
feed.push(batch)                                            // => "applied", "duplicate" or "gap"

applyBatchTo(batch, tree)                                   // one batch, folded in place
```

`TaskTree` folds batches the same way the Ruby side does, and a test holds the two to the same percent for every node. `tree.apply(batch)` returns `"applied"`, `"duplicate"` for one it already has, or `"gap"` - the tree is then `stale` until a batch with `prev` 0 arrives. `followEventSourceAt` reconnects on a gap, and the server starts it over from a fresh squash; with `followBatches` that is yours to do.

`get(path)`, `root`, `childrenOf(node)`, `each()` (pre-order), `percentOf(node)`, `complete(node)`, `fraction(node)`. Elapsed times are measured on the writer's clock: `now()` takes off the smallest gap seen between this clock and a batch's commit time, which has the least time in transit in it.

### Drawing once a frame

A stream can carry thousands of batches a second. Every batch is still folded as it arrives, but `onChange` is called at most once an animation frame, with what changed since the last call:

| `changes` | |
|---|---|
| `batches` | How many were folded. |
| `touched` | Keys (`path.join("/")`) of the nodes changed, and every one above them. |
| `events` | What a renderer must not miss even if a later batch in the same frame hides it, in order: `done`, `fail` (with the error), `cancel`, `say`, `reset`, `gap`. |
| `structure` | Rows came, went or moved. |

`RenderQueue` in `render_queue.js` does this; pass `{ schedule }` for a clock other than `requestAnimationFrame`.

### row_view.js

`rowView(tree, node)` is what one row shows, worked out once for every renderer: `key`, `path`, `depth`, `name`, `status`, `stale`, `percent`, `indeterminate`, `measure` (`12 MB / 40 MB`, `33 / 40`, `42%`, an elapsed time), `message` (with the rate and time left for a counted task), `icon`, `cancelable`.

### Stimulus

```html
<div data-controller="task-tree"
     data-task-tree-url-value="/jobs/42/progress"
     data-task-tree-cancel-url-value="/jobs/42/cancellations"
     data-task-tree-cancel-token-value="..."></div>
```

```js
import TaskTreeController from "/task_progress/stimulus_controller.js"
application.register("task-tree", TaskTreeController)
```

Changing the url value follows the new stream. Draws once a frame at most, and then only the rows that changed. Fires `task-tree:render` after each draw, and `task-tree:cancel` (with the task's `path` and `name`) when a cancel button is pressed - prevent it to handle the cancel yourself; otherwise it creates a cancellation at the cancel-url value.

### React

```js
import { TaskTreeView, useTaskTree, mountTaskTree } from "/task_progress/react_task_tree.js"

<TaskTreeView url="/jobs/42/progress" cancelUrl="/jobs/42/cancellations" cancelToken={token} />
<TaskTreeView url="/jobs/42/progress" onCancel={async (row) => ...} />  // return false to release the button
const tree = useTaskTree(url)                                            // draw it yourself
mountTaskTree(element).followEventSourceAt(url, { cancelUrl, cancelToken })  // on a page that is not a React app
```

### Rows and cancel buttons

`task_tree.css` styles the rows both renderers draw: one fixed height, so nothing jumps as glyphs change. The palette sits on `:where(.tree)`, which weighs nothing - any selector of yours overrides it. A cancelable task that has not finished gets a cancel button right of its bar; the column is there on every row, so bars line up. Pressed, the button stays pressed until the cancel comes down the stream - or comes back to life if the server says no.

`requestCancel(url, path, { token })` posts `{path, token}` as JSON, for your own buttons.

## The wire format

One batch per line:

```json
{"log":"k7p2qd9z4m","prev":11,"seq":12,"at":1730000000.123,"ops":[[["x3k0"],"add",5],[["x3k0"],"note","Reading"]]}
```

| Op | Value | |
|---|---|---|
| `open` | `{name, total, weight, expect, indeterminate, unit, cancelable}` | A new node. |
| `meta` | any of open's, and `stale` | Attributes changed after the fact. |
| `set` | 0..100 | A percent. |
| `add` | an integer | A delta to the count. |
| `note` | text | A message. |
| `done` | - | |
| `fail` | an error hash | `{class, message, backtrace, cause}` |
| `cancel` | text or - | The reason. |
| `prune` | - | Drop every descendant of the node. |
| `put` | a whole node | What a squash is made of. |
| `say` | text | A line to print; changes nothing in the tree. |

Reading is for writers we do not trust - a subprocess, a stream relayed from elsewhere - so nothing is taken at its word. A batch with anything wrong in it is dropped whole: `prev` must be below `seq`; at most 100,000 ops and 32 path levels; every id `[0-9a-z]{1,16}`; text scrubbed to UTF-8 and cut at 2,000 characters; numbers clamped; at most 200 backtrace lines and 3 causes; and nothing in an error is ever turned into a class. A line over 4 MB is skipped, and one cut off by a writer that died is never read. Log ids, like task ids, are lower case only, so neither can clash with another on a filesystem that ignores case.

`Wire.dump(batch)`, `Wire.parse(line)`, `Wire.to_h(batch)`, `Wire.from_h(hash)`, `Wire.each_batch(io)`.

## Testing

- `TerminalOutput.new(io, interval: nil)` redraws on every batch, with no thread. `term.lines(snapshot)` gives the lines without the terminal control.
- `TaskProgress::Log.new(clock: -> { t += 1.0 })` makes times predictable, and `random: Random.new(1)` task ids.
- `root.log.snapshot` is the tree as it stands, and `TaskProgress::State.fold(events)` folds events of your own.
- An output is any lambda: `root.add_output { |batch, _| batches << batch }`.

## The bench

`bin/dev` starts it on http://localhost:9292 (`PORT=` for another). Each scenario puts one part of TaskProgress under a light:

| Scenario | |
|---|---|
| Import | A counted download, workers on threads, a task with no measure, an engine in a subprocess under its own mount. The download, the workers, the wait, the engine and its watermarking step - inside the subprocess - can each be canceled. |
| Import (engine fails) | The engine raises halfway; its error crosses the pipe, fails the mount and then the job. |
| 16 threads, one tree | Thousands of batches a second - the inspector keeps up, with no gaps, at one draw a frame. |
| 120 tasks in random order | A wide tree filled in by eight threads; the terminal's trimming. |
| Six levels deep | Weighted means all the way down. |
| Nothing to count | Indeterminate tasks: spinners, elapsed time, the latest note. |
| Transactions | Each step hands over to the next in one batch, so no frame shows two running, or none. |
| Squashed relay | A tree relayed through `BufferedOutput` and `PublishingOutput` into a mount, as a job publishing to Sossego would. |
| Gap, stale, recover | A mount loses a batch, goes stale, and recovers from a fresh squash. |
| Ractors | Four Ractors, each mounted here. Ruby 4.0. |

Both renderers follow the same job side by side, over a stream of their own each, with a stream inspector counting frames, ops, resets, gaps, duplicates, reconnects, batches and renders a second. You can cancel a job or any cancelable task, cut the stream every N frames to watch it resume, or join a running job late. The page and its scripts are served by Assiette, a development dependency only.

The terminal demo is `ruby -Ilib examples/cli_demo.rb`, and the same piped: `ruby -Ilib examples/cli_demo.rb | cat`.
