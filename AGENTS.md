# Working on TaskProgress

## Naming

- **No deep namespaces.** Every class and module sits directly under `TaskProgress`: `TaskProgress::PublishingOutput`, never `TaskProgress::Outputs::Publish`. A class is not nested in another class either - `TaskProgress::Transaction`, not `TaskProgress::Log::Transaction`.
- Group by name, not by module: what a class is goes at the end of its name. Outputs end in `Output` (`TerminalOutput`, `BufferedOutput`).
- One class per file, flat in `lib/task_progress/`, named after the class: `PublishingOutput` lives in `publishing_output.rb`.

## Ruby

- Ruby 3.4 and up. Ractor code runs on 4.0 only - keep it behind `TaskProgress::RACTORS`, and run the tests on both.
- No runtime dependencies. `progressive_io` is optional and loaded on first use; Puma, rackup and Assiette are for the bench only.
- Comments are few, and say why rather than what. A spaced hyphen ` - `, never an em-dash.

## Tests

`bundle exec rake test` runs the Ruby tests and the JS ones (`test/js`, through Node). The parity test holds the browser client's fold to the Ruby one for random trees: a change to how a tree folds or how percents work goes into `State` and `js/task_tree.js` together.

A change to the wire format touches `Wire` (what a reader accepts), `js/task_tree.js`, and the op table in the MANUAL.

## JS

`js/` ships in the gem: plain ES modules, no build step, relative imports inside the directory, and bare names (`@hotwired/stimulus`, `react`, `react-dom/client`, `htm`) for what the host page's import map provides. Rows keep one fixed height.

## Docs

The README is the short version - keep it short, and keep its opening paragraphs as they were written. The MANUAL documents everything: a change to the API goes into it in the same commit.

## The bench

`bin/dev` serves it on http://localhost:9292. A new feature gets a scenario there, or a part in one, so it can be seen working.
