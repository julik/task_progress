# Changelog

## 1.0.0 - unreleased

The first release. TaskProgress was extracted from ghost_ink and rebuilt on an event log; there
is nothing before it to be compatible with.

- Progress as a log of change events, committed as numbered batches under one lock, and squashed for whoever joins late.
- Trees of tasks: counted, weighted, indeterminate, expected. A task finishes at its total, and a parent only once everything under it ends.
- Bars, `iterate`, `track_io` (with progressive_io), and a CLI that draws a tree on a terminal and an execution log on CI.
- Outputs: a terminal, an execution log, NDJSON, buffered and squashed, a Ractor port, Turbo Streams, any lambda.
- Mounts: subtrees fed from subprocesses (over a pipe, with cancels going the other way), Ractors (Ruby 4.0) and streams.
- Canceling, from any thread or from outside, with signed cancel tokens and a cancellations resource.
- Handing work off through a stream - in memory, or Redis - to a job or a worker anywhere: `handoff`, `adopt`, `follow`, `fetch`. Followers notice a worker that went away, and a retry starts the tree over as the next attempt.
- One run writes a handed-off tree at a time: a run that was taken over from cannot take it back, cancel requests name the run they are for, and a write that fails is made good by the next.
- ActiveJob: a tree is a job argument like any other, and the job's `perform` is its work.
- Server-Sent Events, long polling, and a browser client with Stimulus and React on top - drawn once a frame, with tasks that run in the browser grafted under the server's.
- Turbo: a tree drawn as HTML and morphed into every page that shows it, from wherever the job runs.
- Big trees fold their finished and waiting siblings into a row each, in every renderer.
- `task_progress watch KEY` draws a handed-off tree in a terminal.
- `TaskProgress.for_page(key)` hands a page signed links to a handed-off tree and its snapshot, which `TreesApp` - mounted by the Railtie - answers; the key never leaves the server. React gets `useTaskTree(progress)` and `<TaskTreeView progress onComplete onFail>`, Stimulus a `progress` value, and both fall back from SSE to polling by themselves.
- The browser client comes with TypeScript declarations. `task_progress vendor` (or `rails task_progress:vendor`) copies it into an app as the `task_progress` package, for Vite or esbuild; with importmap-rails, the Railtie pins `task_progress`, `task_progress/react` and the rest by itself. Rails warns at boot when a vendored copy is older than the gem.
- Tasks that run in the browser can be drawn on their own, with no server tree: `followLocal(work)`, `<TaskTreeView local={work} />`, or the Stimulus controller's `show(work)`. RECIPES.md has upload progress done that way.
- Stream stores take a `namespace:`; an unset one raises in production rather than keep trees in one process.
- In Rails, the browser client is served at `/task_progress/js`, and cancel buttons send the page's CSRF token.
- RECIPES.md: whole setups to start from.
- Test helpers: `outline`, `RecordingOutput`, `TaskProgress::Assertions`.
- The wire format carries its version, `v: 1`; readers drop batches in any other.
- Typed with inline RBS, checked by Steep; the signatures ship with the gem.
