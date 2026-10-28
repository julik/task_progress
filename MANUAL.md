# TaskProgress manual

Everything TaskProgress does, and how. The [README](README.md) is the short version, and [RECIPES](RECIPES.md) has whole setups to copy from.

- [How it works](#how-it-works)
- [Tasks](#tasks)
- [How far along a task is](#how-far-along-a-task-is)
- [Finishing](#finishing)
- [Bars, loops and IO](#bars-loops-and-io)
- [On the command line](#on-the-command-line)
- [Outputs](#outputs)
- [Streaming a branch](#streaming-a-branch)
- [Other processes and Ractors](#other-processes-and-ractors)
- [Handing work off](#handing-work-off)
- [Canceling](#canceling)
- [Writing work that can be canceled](#writing-work-that-can-be-canceled)
- [Canceling from outside](#canceling-from-outside)
- [Server-Sent Events](#server-sent-events)
- [Polling](#polling)
- [A handed-off tree on a page](#a-handed-off-tree-on-a-page)
- [The browser client](#the-browser-client)
- [Turbo](#turbo)
- [Big trees](#big-trees)
- [The wire format](#the-wire-format)
- [Testing](#testing)
- [The bench](#the-bench)

## How it works

A tree of tasks lives in a **log**. Nothing in the tree is changed directly: every change is an **event**, and events are committed in **batches** - one batch per transaction, numbered by `seq`, each naming the one before it in `prev`. The log holds one lock, so changes from any number of threads land in one order.

The tree as it stands is what you get by folding every batch, in order. A batch with `prev` 0 starts over from nothing, which is how a **squash** announces itself: the whole tree so far as one batch, which is what a reader that joins late starts from. Folding the squash gives back the same tree.

**Outputs** get every batch, in order, outside the lock - so a slow output never holds up a worker that is waiting for the lock, though it does hold up whoever committed (wrap it in `BufferedOutput` if that matters). A terminal redraw, a pipe to a parent process, an SSE stream to a browser and a Sossego stream are all outputs.

A task is named by its **path** from the root: `[]` is the root, `["x3k0", "00af"]` a child of the root's child `x3k0`. Each id is four random base36 characters, unique among its siblings, and never reused within a log - so a path is a sound key for a React row, and a pruned task's path never turns up on another one. A handle (`TaskProgress`) is just a log and a path: cheap to make, and equal to any other handle for the same task.

Timestamps are for display only. Order is `seq`, `prev`, the order of events in a batch, and the order children were opened in.

`require "task_progress"` loads one file. Each class loads when it is first used, and brings what it needs from the standard library with it - `json` comes with `Wire` and `Mount`, `openssl` with `Token` - so a program that only keeps a tree in memory never loads either. `TaskProgress.eager_load!` loads everything at once, for a server that forks its workers and wants them to share the code; `TrackedIO` is skipped when `progressive_io` is not installed.

## Tasks

```ruby
root = TaskProgress.new("Import")                     # a tree with no outputs
root = TaskProgress.new("Import", outputs: [output])  # see Outputs
root = TaskProgress.new("Import", outputs: [TaskProgress::SummaryOutput.new { |percent:, message:| job.update!(percent:, message:) }])
```

`TaskProgress.null` is a silent root, for a library's default.

### Opening tasks

```ruby
task = root.subtask("Rows", total: 120)
```

| Option | |
|---|---|
| `total:` | Counted: driven with `advance`/`tick`, reads `count / total`. |
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
| `update(percent, message:)` | Sets the percent of an uncounted task. 100 finishes it. |
| `advance(n = 1, message:)`, `tick(message:)` | Adds to the count. |
| `note(message)` | The latest thing it says, shown on its row. |
| `puts(message)` | A line printed above the tree, which stays. The tree does not keep it - see [Outputs](#outputs). |
| `total=`, `name=` | |
| `done!(message)`, `fail!(error, **extra)`, `cancel!(reason)` | See [Finishing](#finishing) and [Canceling](#canceling). |
| `transaction { }` | Everything in the block lands as one batch, or none of it does. |

`fail!` takes an exception, a message, or nothing. An exception keeps its class, message, backtrace and up to three causes. `extra` goes along with the error: booleans and integers only, a reader drops the rest.

Anything that starts work - a percent, a count, a note, finishing - starts the task and every task above it. A pending task only becomes active when something happens to it.

### Reading them

`name`, `status` (`:pending`, `:active`, `:done`, `:failed`, `:canceled`), `percent`, `fraction` (unrounded, 0..1), `count`, `total`, `message`, `error`, `attempt`, `failed?`, `canceled?`, `finished?`, `complete?`, `cancelable?`, `parent`, `root`, `subtasks`, `find(path)`, `outline` and `node` (the whole record, frozen). Reads come from a frozen snapshot, so they are safe from any thread.

`finished?` is the task's own status: done, failed or canceled. `complete?` is the whole subtree: the task done, and everything under it ended - which is what reads 100%. `cancelable?` is the attribute, and not finished yet.

`find` takes a path under this task, as an Array of ids or as the ids joined with a dash (`"x3k0-00af"`) - the way the browser client keys its rows.

### Transactions

```ruby
root.transaction do
  current.done!
  following.update(0, message: "Starting")
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
TaskProgress.bar("Importing", total: rows.size).iterate(rows) { |row| import(row) }  # a bar over a collection
root.iterate(files, "Files") { |file| copy(file) }             # a subtask
root.iterate(rows, "Rows").map { transform(it) }               # without a block, an Enumerator
root.iterate(downloader, "Download", total: bytes, step: CHUNK)
```

The total comes from `size`, never `count` - so a lazy enumerator stays lazy, and one with no size just counts. The task is done when the loop ends and failed with the error if the block raises. It advances in steps of a thousandth of the total, not once per item, so a loop over cheap items is not held up by its own progress; each item counts `step:` (1).

### track_io

```ruby
download.run { IO.copy_stream(download.track_io(file), dest) }
download.track_io(file) { |io| ZipKit::FileReader.read_zip_structure(io: io) }  # done when the block returns
```

Reading the IO advances the task by bytes: `read`, line reads, `readpartial` and so `IO.copy_stream`. Readers seek - ZipKit reads the end of an archive first - so only the furthest position counts. It moves in steps of 0.1% of the total. It needs the optional `progressive_io` gem and an IO with a position; for a pipe or a socket, `advance(chunk.bytesize)` as you go.

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

An output that raises does not stop the others; `log.on_error = ->(error, output) { }` hears about it (it warns by default).

| Output | |
|---|---|
| `TerminalOutput.new(io, interval: 0.1, erase: false)` | The redrawn tree. `interval: nil` redraws on every batch, with no thread. |
| `ExecutionLogOutput.new(io, interval: 3, heartbeat: 60)` | Finished lines, for CI and pipes. |
| `SummaryOutput.new { \|percent:, message:\| }` | The root's percent and the latest thing said, called only when either changes. For a progress column in a database. |
| `NDJSONOutput.new(io)` | One batch per line, for a Mount at the other end of a pipe. |
| `PublishingOutput.new(stream, event_name: "task_progress")` | Each batch as a JSON-ready Hash to anything with `publish(name, payload)` - a Sossego stream. |
| `StreamOutput.new(stream, key, heartbeat:)` | Each batch to a stream, with snapshots for late readers - what `handoff` and `adopt` write through, see [Handing work off](#handing-work-off). |
| `RecordingOutput.new` | Keeps every batch, for a test - see [Testing](#testing). |
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
mount.read(io)     # reads NDJSON until EOF
mount.stale?
```

A batch already applied is a duplicate - ordinary after a reconnect. One that does not follow the last is a gap: the subtree is marked stale, and stays so until a batch with `prev` 0 replaces it whole. Anything the remote sends is distrusted (see [The wire format](#the-wire-format)).

### Spawn

`spawn` starts a command with `TASK_PROGRESS_FD=3` pointing at a pipe it follows, and `TASK_PROGRESS_CONTROL_FD=4` pointing at one it writes cancel requests to. The child uses `TaskProgress.cli`, which finds both; neither pipe is handed down to processes the child starts. Its stdout and stderr stay its own.

- A child that exits without finishing its root fails the mount. One that exits with an error fails it with that.
- Canceling the mount asks the child to cancel its root, and sends TERM if it is still running `grace` seconds later. The pid is only ever signaled while it is still ours.
- Interrupted (Ctrl-C, a timeout), `spawn` terminates the child at once and cancels or fails the mount.
- The parent may end the mount itself, when the remote went away: `mount.task.done!`, `fail!`, `cancel!`. Whatever the remote sends after that changes nothing.

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

A Ractor may be the first to touch a class - `RactorOutput`, `Log`, `State` - and so load it: on 4.0 a `require` from a Ractor other than the main one is handed to the main Ractor, which loads the file while the Ractor waits. The main Ractor can be blocked on `port.receive` and it still works. To keep loading out of the Ractors altogether, call `TaskProgress.eager_load!` before starting them.

## Handing work off

Create a tree here, and let whatever does the work - a job, a worker, another machine - write to it there:

```ruby
import = TaskProgress.handoff("Importing", cancelable: true)   # in the controller
ImportJob.perform_later(upload, import)                          # ActiveJob takes the task itself

class ImportJob < ApplicationJob
  def perform(upload, import)                                    # ...and gets it back adopted
    import.subtask("Rows", total: upload.rows) { |rows| ... }
  end
end
```

The tree lives in a **stream** - Redis in production - under its `key`, so anything that reaches the same stream can follow it: a page, an SSE or polling endpoint, a terminal, a parent's tree. Until a worker takes it up it waits as `pending`, which is what a page shows while the job sits in the queue.

| | |
|---|---|
| `TaskProgress.handoff(name, **attributes)` | A root to hand off. `root.key` names it: `"task_progress:{k7p2qd9z4m}"`. |
| `TaskProgress.adopt(key) { \|root\| ... }` | Takes it up, as a root of its own with the name and attributes it was handed off with. The block is its work, as with `run`. Without a block, call `root.log.close` when the work is over. |
| `TaskProgress.follow(key)` | A tree mirroring it, kept up to date on a thread of its own. `log.close` stops following. |
| `TaskProgress.fetch(key)` | The same, read once - for a page, or a single poll. |
| `mount.follow_stream(stream, key)` | Mounts it under a node of a live tree, see [Other processes](#other-processes-and-ractors). |

Adopting **starts the tree over**: the worker writes a fresh log whose first batch has `prev` 0, and followers replace what they had. That is what makes a retry clean. Whoever wrote before - the side that handed it off, a run that was given up on - is ignored from then on (a mount fed from the stream answers its batches with `:superseded`, a fifth outcome next to those of `<<`), so two writers never interleave.

### The stream store

```ruby
TaskProgress.stream_store = TaskProgress::RedisStreamStore.new(RedisClient.config(url: ENV["REDIS_URL"]).new_pool)
```

The stream store is where handed-off trees are kept: one connection, set once, the way `Rails.cache` is - and every tree in it a stream of its own, under a key of its own, which nothing else reads or writes. Two users' imports share a Redis and a connection pool, and nothing more. Any call that touches it takes `stream_store:`, for a tree, a tenant or a test kept somewhere else.

Until it is set, `TaskProgress.stream_store` is a `MemoryStreamStore` - good for one process (the tests, the bench, an app that runs its jobs in the process that serves its pages) and for nothing else. In production (`RAILS_ENV`, `RACK_ENV` or `APP_ENV`) an unset one raises rather than quietly keep trees where no other process can see them; set a `MemoryStreamStore` yourself if that is what you mean. In Rails, `config.task_progress.stream_store` sets it too. `RedisStreamStore` takes a [redis-client](https://github.com/redis-rb/redis-client) connection or pool, or a redis-rb `Redis`; neither is a dependency, and nothing loads one. It needs Redis 6.2 or later. A follower waiting for news holds its connection while it waits, so size the pool for the followers you expect at once; a redis-rb `Redis` is a single connection, which a follower would block for everything else.

Under one key, `StreamOutput` keeps:

| Key | |
|---|---|
| `task_progress:{id}` | Every batch, one stream entry each. |
| `…:snapshot` | The tree squashed into one batch, and the entry it is as of. A follower starts here. |
| `…:beat` | There while the worker is alive, gone a few seconds after it is not. |
| `…:control` | Cancel requests, the other way. |

The braces make the id a Redis Cluster hash tag, so all five land on one node. `RedisStreamStore.new(redis, namespace: "tenant-42")` puts every key under a namespace as well, for apps or tenants that share a Redis and must stay apart even so. A snapshot is taken at the first batch, every two seconds after and when the root finishes, and each one trims the stream back to the one before - so however spammy the work, the stream stays a couple of seconds long. Once the root has finished, it all expires after a day (`retain:`). A worker sends its batches squashed, ten times a second at most (`interval:`).

Another kind of stream store is anything with `append(key, data) -> id`, `read(key, after:, timeout:) -> [[id, data]]`, `get`, `set(key, value, expires_in:)`, `delete`, `trim(key, before:)` and `expire(key, seconds)`.

### When the worker goes away

A worker beats every second (`heartbeat:`), and takes the cancel requests that came while it does. A follower that has seen it beat and then hears nothing marks the tree stale, and after a minute of that (`give_up_after:`) fails it - "Lost touch with whoever was working on it". A tree nobody has taken up yet is waiting, not silent, and never goes stale.

A failed tree is still followed: if the work is **retried**, the new run replaces the old one, its root says which attempt it is (`root.node.attempt`, drawn as "attempt 2" from the second on), and nothing of the lost run stays mixed in. A tree that is done or canceled is followed no more.

Canceling a follower's root, or one of its cancelable tasks, sends the request back through the stream; the worker cancels it the next time it beats, and the cancel comes back down.

### ActiveJob

With Rails, the Railtie does all of this; without it, call `TaskProgress::JobSerializer.install` once ActiveJob is loaded.

- A tree from `handoff` goes to a job as an argument like any other, and into the queue as its key. A task that lives in this process alone cannot: `ActiveJob::SerializationError`.
- Out of the queue it comes adopted, and the job's `perform` is the root's work: done when it returns, failed with the error when it raises. A canceled task stops the job without failing it.
- A retry - `retry_on`, or the queue's own - adopts it again, as the next attempt.

### Other job runners

Pass the key, and adopt it with a block:

```ruby
Importer.perform_async(upload.id, import.key)

def perform(upload_id, key)
  TaskProgress.adopt(key) { |import| ... }
end
```

`TaskProgress.working_on(arguments) { ... }` is what wraps every ActiveJob: it runs the block as the work of every adopted root among the arguments, and closes them after - for a runner with middleware of its own.

### Watching from a terminal

```
$ task_progress watch "task_progress:{k7p2qd9z4m}" --redis redis://localhost:6379
```

Draws the tree wherever it runs - a terminal, or a CI log - until it finishes, and exits 0 if it was done. Ctrl-C stops watching and leaves the work alone. Needs the redis-client gem.

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
  rows.each { import(it) && t.tick }
end
root.subtask("Publish") { publish! }  # still runs if Rows was canceled
```

**Clean up in `ensure`, or rescue `Canceled` for what only a cancel should undo.** Re-raise it, so `run` sees it:

```ruby
root.subtask("Export", cancelable: true) do |t|
  File.open(tmp, "w") { |f| rows.each { f.puts(it) && t.tick } }
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

**Once you have caught it, stop.** The exception is the cancel: canceling only marks the task, and `Canceled` unwinding the work out of its loop is what actually stops it. Swallow it and carry on, and the work runs to the end while every reader of the tree is told it was canceled - a catch-all `rescue Exception` around each row imports all 100 rows of a task canceled at the 22nd. A `rescue Exception => e; retry` wrapper is worse: it retries into the canceled task, and spins.

Re-raising is the simplest way to stop, since `run` then ends the task. Breaking out, or returning from the block, does as well - which makes room to finish the step at hand first:

```ruby
rows.each do |row|
  import(row)
  rows.tick
rescue TaskProgress::Canceled
  break  # this row is whole - stop before the next one
end
```

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
tokens = TaskProgress::Token.new(ENV.fetch("TASK_PROGRESS_SECRET"))  # 32 bytes or more
token = tokens.issue(root.log.id, expires_in: 3600)  # into the page, next to the stream URL
tokens.verify(params[:token])                         # => what it was issued for, or nil
```

A token is an HMAC-SHA256 over a subject - a log id, a run - and an expiry, checked in constant time. It says the bearer may ask for tasks in that tree to be canceled; which tasks is for `cancelable` to say. Issue one per run, so a page left open from one run cannot reach the next.

`CancellationsApp` takes the requests for a tree that runs in another process, as Rails' cancel buttons do. A cancellation is a resource you create, not a call:

```
POST /task_progress/cancellations    path=x3k0-00af&token=...    (a form, or JSON)
  202  {"path": "x3k0-00af", "state": "requested"}   (a Turbo form gets an empty Turbo Stream instead)
  403  no token, a mangled one, or an expired one
  422  a malformed path
  405  anything but a POST
```

It cannot cancel anything itself: it leaves the request in the store, where the run it is for picks it up - or does not, if it has ended, and the request expires after ten minutes. Either way the outcome shows in the tree.

For a tree in the serving process, call `request_cancel` and answer with what came of it - the bench does, in `examples/web/app.rb`. For one handed off, `TaskProgress.fetch(key).request_cancel(path)` sends the request through the stream, see [RECIPES](RECIPES.md).

## Server-Sent Events

```ruby
TaskProgress::SSE.response(task)                                 # Rack
TaskProgress::SSE.response(key)                                  # a tree handed off - 404 for a key with nothing at it

headers.merge!(TaskProgress::SSE::HEADERS)                       # Rails
self.response_body = TaskProgress::SSE.new(task)
```

First the tree so far, squashed into one batch with `prev` 0, then every batch as it commits - each in a `batch` event whose `id:` is its seq. A browser that reconnects starts over from a fresh squash, which is always right and costs a few puts. It pings every `heartbeat:` seconds (15) while nothing happens, tells the browser to come back after `reconnect:` seconds (2) if the connection drops, and ends once the task it streams has finished - or at once, with an empty tree, for a task that is no longer there. Given a subtask, it streams only that branch.

Given a key, it follows the tree handed off there for as long as it streams, and stops when the stream ends or the server closes it. A client that stops reading gets a fresh squash when it reads on, rather than a backlog that grows for ever.

## Polling

For where SSE does not get through - a proxy that buffers, a host that cuts long responses, a client that is not a browser:

```ruby
TaskProgress::Poll.response(task, env)    # Rack
TaskProgress::Poll.response(key, env)     # a tree handed off - 404 for a key with nothing at it
```

Every answer is the whole tree, squashed into one batch with `prev` 0, with an ETag that says which tree it is. Sent back in `If-None-Match` - weak (`W/"..."`, as a compressing proxy makes it) or not - it gets a 304 until something changes. With `?wait=N` the request is held up to N seconds (`max_wait:`, 25) for a change - long polling, which holds a server thread that long, but answers the moment there is news.

```js
followPollingAt("/jobs/42/poll", (tree, changes) => draw(tree), { poll: 1 })  // every second
followPollingAt("/jobs/42/poll", draw, { wait: 25 })                          // long polling
```

Everything is in seconds. A poll that fails is tried again later and later, up to half a minute apart; long polls go out a quarter of a second apart at the least. Polling stops once the root has finished, or the task is gone. The Stimulus controller polls given a `poll` value (seconds between polls) or a `wait` value (to long-poll); `TaskTreeView` and `useTaskTree` take `poll` and `wait` too.

## A handed-off tree on a page

```ruby
TaskProgress.for_page(video.progress_key)
# => {events: "/task_progress/trees/eyJ…/events", poll: "…/poll", cancel: "…/cancellations",
#     snapshot: {v: 1, log: …, prev: 0, seq: …, ops: […]}}
```

Everything a page needs to show a handed-off tree, as JSON-ready data: a prop for an Inertia or React page, `data-task-tree-progress-value` for the Stimulus controller, `useTaskTree(progress)` / `<TaskTreeView progress>` / `followProgress(progress, draw)` in the browser. `snapshot` is the tree as it stands, so the page draws it before anything comes down the stream. The client follows it over Server-Sent Events, and falls back to polling by itself when those cannot be reached - an error, or nothing at all for five seconds, as from a proxy that buffers.

**The tree's key never reaches the page.** The links carry a `Token` - an HMAC over the key and an expiry (`expires_in:`, an hour) - and `TreesApp` answers them:

```
GET  /task_progress/trees/:token/events          Server-Sent Events
GET  /task_progress/trees/:token/poll            polled or long-polled
POST /task_progress/trees/:token/cancellations   path=x3k0-00af
  202 requested   200 moot   409 not cancelable   403 a bad token   404 no such tree
```

Issuing the token is the authorization: call `for_page` where you have decided the page may see the tree, as you would before rendering anything else of the record's. The Railtie mounts `TreesApp` (`config.task_progress.trees_path`, nil for none) and signs with the app's `secret_key_base`. Outside Rails, mount it yourself and set `TaskProgress.tokens = TaskProgress::Token.new(secret)` and, if it is not at `/task_progress/trees`, `TaskProgress.trees_path`.

A cancel asked of a tree no worker has taken up yet waits for one, which takes it up before it begins the work - so the work never starts.

## The browser client

Plain ES modules in `js/`, shipped with the gem: `TaskProgress.js_path`. Serve the directory under any prefix - imports inside it are relative. With [Assiette](https://github.com/julik/assiette):

```ruby
use Assiette::Server, root: "public", additional_directory_mappings: {"/task_progress" => TaskProgress.js_path}
```

The Stimulus controller and the React component import `@hotwired/stimulus`, `react` and `react-dom/client` by bare name - from `node_modules` in a Vite app, from the import map on a page without a build step. There is no JSX in them.

### task_tree.js

```js
import { followEventSourceAt, followPollingAt, batchFeed, requestCancel, pathKey, TaskTree } from "/task_progress/task_tree.js"

const following = followEventSourceAt("/jobs/42/progress", (tree, changes) => draw(tree))
following.close()

const feed = batchFeed((tree, changes) => draw(tree))  // for batches from anywhere: a WebSocket, ActionCable
feed.push(batch)                                            // => "applied", "duplicate" or "gap"

tree.apply(batch)                                           // one batch, folded in place
```

A path's key is its ids joined with a dash - `pathKey(["x3k0", "00af"])` is `"x3k0-00af"`, and `pathFromKey` splits it back. Ids never contain a dash, so it needs no escaping in a URL, a class name or a data attribute. The root's key is the empty string. As a DOM id, prefix it (`task-x3k0-00af`): an id that starts with a digit needs `CSS.escape` in a selector.

`TaskTree` folds batches the same way the Ruby side does, and a test holds the two to the same percent for every node. `tree.apply(batch)` returns `"applied"`, `"duplicate"` for one it already has, or `"gap"` - the tree is then `stale` until a batch with `prev` 0 arrives. `followEventSourceAt` reconnects on a gap, and the server starts it over from a fresh squash; with `batchFeed` that is yours to do.

A batch in a version of the wire format other than its own is `"unsupported"`, and changes nothing. `get(path)`, `root`, `childrenOf(node)`, `each()` (pre-order), `rows()` (what to draw, see [Big trees](#big-trees)), `percentOf(node)`, `complete(node)`, `fraction(node)`. Elapsed times are measured on the writer's clock: `now()` takes off the smallest gap seen between this clock and a batch's commit time, which has the least time in transit in it.

### Drawing once a frame

A stream can carry thousands of batches a second. Every batch is still folded as it arrives, but `onChange` is called at most once an animation frame, with what changed since the last call:

| `changes` | |
|---|---|
| `batches` | How many were folded. |
| `touched` | Keys (`pathKey(path)`) of the nodes changed, and every one above them. |
| `events` | What a renderer must not miss even if a later batch in the same frame hides it, in order: `done`, `fail` (with the error), `cancel`, `say`, `reset`, `gap`. |
| `structure` | Rows came, went or moved. |

`RenderQueue` in `render_queue.js` does this; pass `{ schedule }` for a clock other than `requestAnimationFrame`.

### Tasks that run in the browser

Some work happens in the browser - hashing files before an upload, encoding a video. `LocalTasks` writes tasks there the way the server writes its own, and `graft` draws them under a server task:

```js
import { LocalTasks } from "/task_progress/local_tasks.js"

const work = new LocalTasks("Hash files", { cancelable: true, weight: 2 })
const ungraft = tree.graft(uploadTask.path, work)           // or the Stimulus controller's graft(path, work)
const file = work.root.subtask("video.mp4", { total: blob.size, unit: "bytes", cancelable: true })
file.advance(chunk.byteLength)                               // done at its total
work.root.done()
```

A task does not stop your work by itself - whether a cancel does is yours to wire, or not. `task.signal` is an `AbortSignal` that aborts with the reason once the task is canceled, for whatever you choose to hand it to; `onCancel(handler)` calls you instead; and `canceled` is there for a loop to check:

```js
const response = await fetch(url, { signal: file.signal })  // a cancel aborts the fetch
file.onCancel((reason) => worker.terminate())                 // or does whatever you say
```

The rules are the server's: a counted task is done at its total, `done()` closes everything still open under it, `fail()` and `cancel()` cancel it. Changing a task that has ended does nothing, so a loop checks `canceled`. Task ids start with `_`, which a server id never does: a graft cannot clash with the tree it is grafted to, and `rowView` marks its rows `local`.

A graft is drawn as a child of its server task and counts towards it. It is kept apart from what the server sends, so a reset or a reconnect puts it back, and it waits for its task if that has not arrived yet. Two rules hold it to the server's tree:

- A server task with browser work still open under it is not through: it reads 99%, and is drawn as running, however soon the server calls it done.
- A server task that fails or is canceled cancels the browser work under it, and its `onCancel` handlers run.

Only this page sees a graft - other viewers, the terminal and the server's own percent know nothing of it. The cancel button on a local task cancels it here, never asking the server. Sharing browser work with the server is in [TODO](TODO.md).

React takes grafts as a prop, `<TaskTreeView url={url} grafts={[{ path, local: work }]} />` - an array written inline is fine.

#### Uploads

The case nearly everyone has: the server opens a task for the files it waits on, and the browser uploads them. `trackUpload(xhr, task)` follows an `XMLHttpRequest`'s upload events - `fetch` has none for request bodies - and ends the task the way the request ends:

```js
import { LocalTasks, trackUpload } from "/task_progress/local_tasks.js"

// The server opened "Receive files" for this, and streams the job's tree to the page
const uploads = new LocalTasks("Upload from this browser", { cancelable: true })
application.getControllerForElementAndIdentifier(treeElement, "task-tree").graft(receiveFiles.path, uploads)

const sent = [...fileInput.files].map((file) => {
  const xhr = new XMLHttpRequest()
  xhr.open("PUT", `/jobs/42/files/${encodeURIComponent(file.name)}`)
  const task = trackUpload(xhr, uploads.root.subtask(file.name, { unit: "bytes", cancelable: true }), { abortOnCancel: true })
  xhr.send(file)
  return task.whenFinished()
})
const endings = await Promise.all(sent)  // "done", "failed" or "canceled", one per file
endings.every((ending) => ending === "done") ? uploads.root.done() : uploads.root.fail(new Error("Not every file made it"))
```

- The task's total is the body's size, learned from the first progress event, and its count the bytes sent. Sending the last byte does not finish it - the server has yet to answer.
- A 2xx answer finishes it. Any other status fails it with that status, as do a network error and a timeout. An abort cancels it.
- It only reports, unless told otherwise: with `abortOnCancel: true`, canceling the task aborts the request - its cancel button, `uploads.root.cancel()`, or the server canceling "Receive files", which cancels the whole graft and every upload with it. Without it, a canceled task keeps its ending however the upload goes on.
- Until every upload has ended and `uploads.root` is done, "Receive files" stays below 100%, even once the server calls it done.

`whenFinished()` resolves with how a task ended, and `setTotal(n)` sets a total learned only once the work has started.

### row_view.js

`rowView(tree, node)` is what one row shows, worked out once for every renderer: `key`, `path`, `depth`, `name`, `status` (a task done with something still running under it shows as `active`), `stale`, `local`, `percent`, `indeterminate`, `measure` (`12 MB / 40 MB`, `33 / 40`, `42%`, an elapsed time), `message` (with the rate and time left for a counted task), `icon`, `cancelable`.

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
import { TaskTreeView, useTaskTree, createTaskTreeRoot } from "/task_progress/react_task_tree.js"

<TaskTreeView url="/jobs/42/progress" cancelUrl="/jobs/42/cancellations" cancelToken={token} />
<TaskTreeView url="/jobs/42/progress" onCancel={async (row) => ...} />  // return false to release the button
const tree = useTaskTree(url, { poll, wait, grafts })                    // draw it yourself
createTaskTreeRoot(element).render({ url, cancelUrl, cancelToken })      // on a page that is not a React app
```

### Rows and cancel buttons

`task_tree.css` styles the rows both renderers draw: one fixed height, so nothing jumps as glyphs change. The palette sits on `:where(.tree)`, which weighs nothing - any selector of yours overrides it; `--stripe` is the light stripe of the barber pole a task with no measure is drawn as, which crawls along while it runs and stands still for whoever prefers reduced motion. The terminal draws the same pole, `╱╱╱░░░`. A cancelable task that has not finished gets a cancel button right of its bar; the column is there on every row, so bars line up. Pressed, the button stays pressed until the cancel comes down the stream - or comes back to life if the server says no.

`requestCancel(url, path, { token })` posts `{path, token}` as JSON, for your own buttons.

## Turbo

A tree can be drawn by Turbo, with no JavaScript of your own: the server draws it as HTML, and Turbo morphs each frame into the page. It is the easiest way to show a job's progress in a Rails app, and it works across processes - the job draws, Action Cable carries the frames to whichever server holds the page.

### In Rails

```ruby
TaskProgress.broadcast(import, "Importing") { |root| ... }    # in a job, anywhere
```

```erb
<%= task_progress_tree @import %>                               <%# in its page %>
```

Then put `task_tree.css` on the page, and import `task_progress_clock.js` for elapsed times to tick. The Railtie serves `js/` as it is at `/task_progress/js` (`config.task_progress.js_path`, nil for none): `<link rel="stylesheet" href="/task_progress/js/task_tree.css">`, and `pin "task_progress/clock", to: "/task_progress/js/task_progress_clock.js"` in the import map.

- **Every frame is the whole tree**, drawn by HTMLRenderer and sent as `<turbo-stream action="replace" method="morph">`, at most every `interval:` seconds (0.25) however spammy the job is. A Turbo Stream has no seq and no gaps to notice; a page that missed a frame, or joined late, is set right by the next one. Morphing changes only what differs, so a bar eases to its new width.
- **The last frame is kept in `Rails.cache`**, under `task_progress/<dom_id>`, for the helper to draw before the first broadcast arrives.
- **The stream is `[record, :task_progress]`**, and the tree's element has the id `dom_id(record, :task_progress)`.
- **Cancel buttons are plain forms.** A cancelable task's button posts its path and a signed token (Token, keyed off the app's `secret_key_base`) to `/task_progress/cancellations`, a route the Railtie adds. The job is in another process, so the route cannot cancel it: it leaves the request in `Rails.cache`, where the job looks for it every `poll:` seconds (1) and decides, as it does for any request. Its next frame shows the cancel. Set `config.task_progress.cancellations_path` to put the route elsewhere, or to nil for none.

`to:`, `store:`, `tokens:`, `cancel_url:` and `renderer:` override what Rails would give; `interval:` and `poll:` are the seconds between frames, and between looks for cancel requests. With a block, `broadcast` runs it as the root's work and returns its value; without one it returns the root, finished at exit.

### Without Rails

Nothing of the above needs Rails - only the defaults do:

```ruby
TaskProgress.broadcast("import-tree", "Importing", to: ->(frame) { hub.publish(frame) }, store: TaskProgress::MemoryCache.new) { ... }
```

`to:` gets each frame, a `<turbo-stream>` element as a String; `store:` is anything with `read`, `write(key, value, expires_in:)` and `delete`, as `Rails.cache` and `MemoryCache` are. `CancellationsApp.new(store:, tokens:)` is the Rack app behind the cancel buttons.

For a tree in the serving process, `TurboSSE` streams it straight to a page, over Server-Sent Events:

```ruby
TaskProgress::TurboSSE.response(task, renderer: TaskProgress::HTMLRenderer.new(id: "tree"), source: "tree-source")
```

```html
<turbo-stream-source id="tree-source" src="/jobs/42/turbo"></turbo-stream-source>
<div id="tree" class="tree"></div>
```

When the task finishes it sends the last frame and removes the element with the id `source:` - the `<turbo-stream-source>` - so the browser does not reconnect to a finished stream. Without `source:` the browser comes back every `reconnect:` seconds (2), and gets the last frame each time. Given a key instead of a task, it follows the tree handed off there. The bench's third pane is drawn this way.

### Drawing rows your own way

HTMLRenderer draws the rows the browser client draws, with the same classes. Subclass it and override `row(snapshot, path, node, depth:)`, or pass `renderer:` anything that answers `id` and `render(snapshot, from = [])` - an object that renders one of your partials with `ApplicationController.render`, say.

## Big trees

Where a task has more than 12 children, every renderer - the terminal, `HTMLRenderer`, the Stimulus controller, the React component - folds them: what is done (save the last three to finish) into one row ahead of the rest, "✓ 9,812 more done", and what is still waiting (save the first three) into one after them, "· 340 more waiting". What is running, failed or canceled is always drawn. `State#rows` and `TaskTree#rows()` make the rows, the same ones on both sides; a folded row's path is its parent's with `~done` or `~pending` after it, which no task id can be.

The tree itself keeps every task. What that costs, from `examples/benchmark.rb` on an M-series Mac:

| | |
|---|---|
| `tick` with no outputs | ~110,000 a second |
| `tick` adopted, to a stream | ~80,000 a second |
| `tick` from 4 threads on one tree | ~85,000 a second |
| `subtask` with 100,000 siblings | ~68,000 a second |
| Memory | ~800 bytes a task |
| Squashing 100,000 tasks | 0.9s |
| Drawing 100,000 siblings, folded, as HTML | 0.3s |

A change copies only the tasks it touched, so a snapshot of a big tree costs what changed, not the whole tree. A tree of a hundred thousand tasks is fine to work on; drawing it many times a second is not - put the drawing behind a `BufferedOutput`, as `broadcast` and `adopt` do.

## The wire format

One batch per line:

```json
{"v":1,"log":"k7p2qd9z4m","prev":11,"seq":12,"at":1730000000.123,"ops":[[["x3k0"],"add",5],[["x3k0"],"note","Reading"]]}
```

`v` is the version of the format, 1 for as long as 1.x lasts. Readers - `Wire` and `task_tree.js` alike - take their own version only, and drop a batch in any other the way they drop a garbled one. So in a deploy where old workers and new web processes overlap, a newer writer's tree is left alone rather than drawn wrong.

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

```ruby
class ImportTest < Minitest::Test
  include TaskProgress::Assertions

  def test_import
    recording = TaskProgress::RecordingOutput.new
    import = TaskProgress.new("Import", outputs: [recording])
    Importer.new(progress: import).run
    assert_task_complete import
    assert_task_failed import.subtasks.last, with: /row 12/
    assert_includes recording.said, "Skipped 3 rows"
  end
end
```

`task.outline` is the task and everything under it as plain Hashes - name, status and percent, and count, total, message and error where there are any - to compare against, or print:

```ruby
{name: "Import", status: :done, percent: 100, children: [
  {name: "Rows", status: :failed, percent: 40, count: 4, total: 10, error: "RuntimeError: row 5"}]}
```

`assert_task_complete`, `assert_task_failed(task, with:)` and `assert_task_canceled` show the whole tree's outline when they fail. `RecordingOutput` keeps every batch: `batches`, `events(op)`, `said` and `outline`.

For the tests of code that draws or relays trees:

- `TerminalOutput.new(io, interval: nil)` redraws on every batch, with no thread. `term.lines(snapshot)` gives the lines without the terminal control.
- `TaskProgress::Log.new(clock: -> { t += 1.0 })` makes times predictable, and `random: Random.new(1)` task ids.
- `root.log.snapshot` is the tree as it stands, and `TaskProgress::State.fold(events)` folds events of your own.
- An output is any lambda: `root.add_output { |batch, _| batches << batch }`.

The gem's own suite also drives the bench in a headless Chrome, through [Ferrum](https://github.com/rubycdp/ferrum) (`test/browser_test.rb`): it starts the bench on Puma in the test process, clicks a scenario, presses cancel buttons and reads the rows off both panes - that they end alike, that a cancel reaches the server, that a cut stream resumes whole, and that work grafted from the page holds the job below 100%. Without a Chrome it skips.

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
| Handed off, lost, retried | A job handed off to a worker process through Redis - or a thread, without one - and mounted from the stream. Halfway the worker is killed: the tree goes stale, then fails; a retry adopts it as attempt 2 and finishes. |

Both renderers follow the same job side by side, over a stream of their own each, with a stream inspector counting frames, ops, resets, gaps, duplicates, reconnects, batches and renders a second. You can cancel a job or any cancelable task, cut the stream every N frames to watch it resume, have the Stimulus pane long-poll instead of streaming, or join a running job late. "Run work in this browser" grafts pretend file hashing under the job's root in both panes: the job stays below 100% until it is through, however soon the server finishes. The page and its scripts are served by Assiette, a development dependency only.

The terminal demo is `ruby -Ilib examples/cli_demo.rb`, and the same piped: `ruby -Ilib examples/cli_demo.rb | cat`.
