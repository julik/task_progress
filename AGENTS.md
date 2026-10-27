# Working on TaskProgress

## Naming

- **No deep namespaces.** Every class and module sits directly under `TaskProgress`: `TaskProgress::PublishingOutput`, never `TaskProgress::Outputs::Publish`. A class is not nested in another class either - `TaskProgress::Transaction`, not `TaskProgress::Log::Transaction`.
- Group by name, not by module: what a class is goes at the end of its name. Outputs end in `Output` (`TerminalOutput`, `BufferedOutput`).
- One class per file, flat in `lib/task_progress/`, named after the class: `PublishingOutput` lives in `publishing_output.rb`.
- Nothing is required up front: a new file gets an `autoload` in `lib/task_progress.rb`, and requires the stdlib it needs (`json`, `openssl`) itself.

## Ruby

`bundle exec standardrb --fix` after every change; a change is not done until `bundle exec standardrb` passes - `bundle exec rake` runs it with the tests, and CI runs it too. Standard is locked to one version in the Gemfile and told `ruby_version: 3.4` in `.standard.yml`, so the style is the one Ruby 3.4 allows, whichever Ruby runs it. A cop that is wrong for one line gets a `# rubocop:disable Cop/Name -- why` on that line, never a rule switched off for everyone.

- Ruby 3.4 and up. Ractor code runs on 4.0 only - keep it behind `TaskProgress::RACTORS`, and run the tests on both.
- No runtime dependencies. `progressive_io` is optional and loaded on first use; Puma, rackup and Assiette are for the bench only.
- Comments are few, and say why rather than what. A spaced hyphen ` - `, never an em-dash.

## Tests

`bundle exec rake test` runs the Ruby tests, the JS ones (`test/js`, through Node), and the browser tests (`test/browser_test.rb`), which drive the bench in a headless Chrome through Ferrum - clicking what a person would click, and reading what they would see. They skip without a Chrome; a change to the renderers or the bench gets one there. The parity test holds the browser client's fold to the Ruby one for random trees: a change to how a tree folds or how percents work goes into `State` and `js/task_tree.js` together.

A change to the wire format touches `Wire` (what a reader accepts), `js/task_tree.js`, and the op table in the MANUAL. Batches carry `v: 1`, and readers drop any other version: within 1.x, a change must stay readable by a reader of today - a new attribute it can ignore, never a new meaning for an old one. Anything else bumps `Wire::VERSION`, and that is a 2.0.

How a big family of tasks folds into rows lives in `State#rows` and `TaskTree#rows` together, and `test/fold_test.rb` holds the two to the same rows.

The stream tests run against a real Redis when one answers on `REDIS_URL` (or localhost), through both redis-client and redis-rb, and skip without one. `RedisStream` must keep working with whatever client it is given - nothing in the gem loads one.

## Types and docs

The type annotations, the type checks and the docs are part of the code, and are kept up to date with it - in the same commit as the change, never after.

- Every method, attribute, constant and instance variable has an inline RBS type: a `#: (Arg) -> Return` line right above a `def`, `#: Type` after an `attr_reader` or a constant, and `# @rbs @ivar: Type` in the class body. A `Data.define` or `Struct.new` gets typed members, with its methods in a `class` body that reopens it.
- Every public class, method, attribute and constant has a doc comment above it, in Markdown - RDoc reads it with `markup: markdown`, and shows the `#:` line as the method's signature. Say what it is for and anything surprising; leave the types to the `#:` line.
- `bundle exec rake types` writes the types out to `sig/generated` and checks the code against them with Steep; commit `sig/generated` with the change. `bundle exec rake doc:check` fails unless everything public is documented. CI runs both, and fails if `sig/generated` is out of date.
- What RBS itself lacks - a core method without its block, a gem without types - goes in `sig/patches.rbs` or a file of its own in `sig/`, never in `sig/generated`.

## JS

`js/` ships in the gem: plain ES modules, no build step, relative imports inside the directory, and bare names (`@hotwired/stimulus`, `react`, `react-dom/client`, `htm`) for what the host page's import map provides. Rows keep one fixed height.

## Docs

Anything a user would notice gets a line in CHANGELOG.md, in the same commit.

The README is the short version - keep it short, and keep its opening paragraphs as they were written. The MANUAL documents everything: a change to the API goes into it in the same commit.

## The bench

`bin/dev` serves it on http://localhost:9292. A new feature gets a scenario there, or a part in one, so it can be seen working.
