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
- ActiveJob: a tree is a job argument like any other, and the job's `perform` is its work.
- Server-Sent Events, long polling, and a browser client with Stimulus and React on top - drawn once a frame, with tasks that run in the browser grafted under the server's.
- Turbo: a tree drawn as HTML and morphed into every page that shows it, from wherever the job runs.
- Big trees fold their finished and waiting siblings into a row each, in every renderer.
- `task_progress watch KEY` draws a handed-off tree in a terminal.
- In Rails, the browser client is served at `/task_progress/js`, and cancel buttons send the page's CSRF token.
- RECIPES.md: whole setups to start from.
- Test helpers: `outline`, `RecordingOutput`, `TaskProgress::Assertions`.
- The wire format carries its version, `v: 1`; readers drop batches in any other.
- Typed with inline RBS, checked by Steep; the signatures ship with the gem.
