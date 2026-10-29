# TaskProgress

Progress for task trees: in one process, across threads, Fibers, Ractors and subprocesses, and out to a terminal or a browser.

Think progress bars, but properly, for complex task trees that the user needs to be updated on. Fit for both the web and the CLI.

The progress is not a mutable structure but an _event log_ which allows task progress collection to be distributed. Every change goes through one lock, which numbers it and commits it as a batch. Outputs receive the batches in order: a terminal renderer, a pipe, an SSE stream, a Sossego stream. A batch is one transaction. On a pipe it is one line, in a stream one event or row, so a reader gets all of it or none of it.

Any run of batches can be squashed into one, and a reader that joins late starts from that squash. This also lends itself perfectly to redraw-the-world UIs like React - but using it with Stimulus is a breeze as well.

<div>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/bench-dark.png">
  <img alt="The bench (bin/dev) mid-job: an import with worker threads and an engine subprocess mounted under its own node, drawn by the Stimulus and React renderers side by side above the stream inspector" src="docs/bench-light.png" width="100%">
</picture>
</div>

The [MANUAL](MANUAL.md) has everything, and [RECIPES](RECIPES.md) whole setups to copy from - a Rails job polled from a page, subprocesses drawn in one terminal, a Rails action streaming to React. This page has what you need first.

## Install

```ruby
gem "task_progress", github: "julik/task_progress"
```

Ruby 3.4 or newer. No runtime dependencies. Typed: RBS signatures ship in `sig/generated`, and the code is checked against them with Steep.

## A bar

```ruby
bar = TaskProgress.bar("Importing", total: rows.size)
rows.each { import(it) && bar.tick }

TaskProgress.bar("Importing", total: rows.size).iterate(rows) { |row| import(row) }  # or let it do the counting
```

```
⠹ Importing  ██████████░░░░░░░░░░ 21/40  19/s  ETA 1.0s  1.1s
```

It finishes at its total, and is finished for you when the program exits. `bar.puts("Skipped row 12")` prints a line above it that stays.

## A tree

```ruby
TaskProgress.cli("Import") do |root|
  download = root.subtask("Download", total: io.size, unit: "bytes")
  rows = root.subtask("Rows", total: rows.size, weight: 3, cancelable: true)

  download.run { copy(download.track_io(io)) }
  rows.run { rows.each { import(it) && rows.tick } }
end
```

A block is a task's work: done when it returns, failed with the error when it raises. A parent reads 100% only once it and everything under it are done. On a terminal the tree redraws in place; piped or on CI it writes an execution log instead - one finished line per thing worth saying, never a redraw.

## With Turbo

In a Rails app with turbo-rails, a job draws its tree in every page that shows it - from whichever process it runs in, with no JavaScript of your own. The tree is drawn for a record, here a `CsvImport` - any Active Record model will do, the one whose page shows the progress:

```ruby
class ImportJob < ApplicationJob
  def perform(csv_import)
    TaskProgress.broadcast(csv_import, "Importing") do |root|
      root.subtask("Rows", total: csv_import.rows.size, cancelable: true) do |rows|
        csv_import.rows.each { import_row(it) && rows.tick }
      end
    end
  end
end
```

```erb
<%# app/views/csv_imports/show.html.erb %>
<%= task_progress_tree @csv_import %>
```

The job draws the whole tree as HTML a few times a second, and Action Cable takes it to every page, where Turbo morphs it in. Cancel buttons are plain forms. Nothing of Rails is needed for the rest of the gem: outside Rails, `to:` says where frames go, and `TurboSSE` streams them to a `<turbo-stream-source>`.

## In a web app

Stream any task - the whole tree, or one branch of it - as Server-Sent Events:

```ruby
# Rails
headers.merge!(TaskProgress::SSE::HEADERS)
self.response_body = TaskProgress::SSE.new(task)
```

and draw it with the browser client that ships in `js/` (`TaskProgress.js_path`): plain ES modules, no build step, with a Stimulus controller and a React component on top.

```html
<div data-controller="task-tree" data-task-tree-url-value="/jobs/42/progress"></div>
```

Where SSE does not get through, `TaskProgress::Poll` answers plain GETs - with a 304 while nothing changed - and `followPollingAt` polls it. Work that runs in the browser itself can be grafted under a server task with `LocalTasks`.

## Handing work off

Create the tree here, and let a job write to it there - through Redis:

```ruby
TaskProgress.stream_store = TaskProgress::RedisStreamStore.new(RedisClient.config(url: ENV["REDIS_URL"]).new_pool)

progress = TaskProgress.handoff("Importing", cancelable: true)
ImportJob.perform_later(csv_import, progress)              # the task is an argument like any other

def perform(csv_import, progress)                          # ...and arrives adopted: perform is its work
  progress.subtask("Rows", total: csv_import.rows.size) { |rows| ... }
end

TaskProgress::SSE.response(progress.key)                   # a page's stream, anywhere that reaches Redis
```

`csv_import` is the same `CsvImport` record as above; `progress` is the tree. `TaskProgress.for_page(progress.key)` is everything a page needs - links with a signed token in them, never the key, and the tree as it stands - for a Stimulus value or an Inertia prop: `<TaskTreeView progress={progress} onComplete={() => router.reload()} />`, with the client from `rails task_progress:vendor` - or pinned by itself, with importmap-rails. The page shows the job queued before a worker has it. A worker that dies goes stale, then fails; a retry starts the tree over as attempt 2. `task_progress watch KEY` draws it in a terminal.

## Across processes

```ruby
engine = root.mount("Engine", weight: 3)
engine.spawn(RbConfig.ruby, "engine.rb")  # engine.rb uses TaskProgress.cli, and reports up a pipe
```

The child's tree lands under the mount, and a cancel goes down to it the same way. Ractors work too, on Ruby 4.0.

## Canceling

```ruby
task.cancel!("Not needed")                     # from any thread
root.request_cancel(path, "From the browser")  # as a request: :canceled, :forwarded, :moot or :refused
```

Whoever works on a canceled task next gets a `TaskProgress::Canceled`, which `run` takes as the end of that work. Blocking work can use `on_cancel { }` to unblock. The renderers show a cancel button on tasks marked `cancelable: true`, and `TaskProgress::Token` signs the right to press it.

## The bench

`bin/dev` starts a bench on http://localhost:9292: pick a scenario and watch it in both renderers side by side, with a stream inspector. Cancel tasks, cut the stream to watch it resume, or join a job late. The terminal demo is `ruby -Ilib examples/cli_demo.rb`.

## License

MIT
