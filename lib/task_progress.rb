# frozen_string_literal: true
# rbs_inline: enabled

# Hierarchical progress for task trees. A TaskProgress is a handle onto one node of a tree; the
# tree itself is a Log of change events, applied and numbered under one lock, which outputs
# receive in order - to draw a terminal, write to a pipe, stream to a browser, or feed a Mount
# that grafts the tree under a node of a tree in another process.
#
#     TaskProgress.cli("Import") do |root|
#       root.subtask("Download", unit: "bytes") { |t| t.track_io(io) ... }
#       root.subtask("Rows", total: rows.size) { |t| rows.each { import(it); t.tick! } }
#     end
class TaskProgress
  # @rbs!
  #   # A task's place in the tree: its ancestors' ids, then its own - `[]` is the root
  #   type path = Array[String]
  #
  #   # Anything that takes the batches a log commits, in order - a lambda will do
  #   interface _Output
  #     def call: (Batch batch, Log log) -> void
  #   end
  #   type output = Object & _Output

  PARTS = File.expand_path("task_progress", __dir__ || ".") #: String
  private_constant :PARTS

  # Each file loads when its constant is first used, along with what it needs from the standard
  # library (json, openssl), so a program pays only for the parts it touches
  autoload :VERSION,            "#{PARTS}/version"
  autoload :Event,              "#{PARTS}/event"
  autoload :OPS,                "#{PARTS}/event"
  autoload :Batch,              "#{PARTS}/batch"
  autoload :State,              "#{PARTS}/state"
  autoload :Node,               "#{PARTS}/node"
  autoload :Journal,            "#{PARTS}/journal"
  autoload :Wire,               "#{PARTS}/wire"
  autoload :Log,                "#{PARTS}/log"
  autoload :Transaction,        "#{PARTS}/transaction"
  autoload :Branch,             "#{PARTS}/branch"
  autoload :Mount,              "#{PARTS}/mount"
  autoload :Squasher,           "#{PARTS}/squasher"
  autoload :SummaryOutput,      "#{PARTS}/summary_output"
  autoload :NDJSONOutput,       "#{PARTS}/ndjson_output"
  autoload :PublishingOutput,   "#{PARTS}/publishing_output"
  autoload :BufferedOutput,     "#{PARTS}/buffered_output"
  autoload :RactorOutput,       "#{PARTS}/ractor_output"
  autoload :TerminalOutput,     "#{PARTS}/terminal_output"
  autoload :ExecutionLogOutput, "#{PARTS}/execution_log_output"
  autoload :SSE,                "#{PARTS}/sse"
  autoload :Refinements,        "#{PARTS}/refinements"
  autoload :CancelToken,        "#{PARTS}/cancel_token"
  autoload :TrackedIO,          "#{PARTS}/tracked_io"
  autoload :HTMLRenderer,       "#{PARTS}/html_renderer"
  autoload :TurboStreamOutput,  "#{PARTS}/turbo_stream_output"
  autoload :TurboSSE,           "#{PARTS}/turbo_sse"
  autoload :MemoryStore,        "#{PARTS}/memory_store"
  autoload :CancellationsApp,   "#{PARTS}/cancellations_app"
  autoload :RailsDefaults,      "#{PARTS}/rails_defaults"
  autoload :MemoryStream,       "#{PARTS}/memory_stream"
  autoload :RedisStream,        "#{PARTS}/redis_stream"
  autoload :StreamOutput,       "#{PARTS}/stream_output"
  autoload :StreamReader,       "#{PARTS}/stream_reader"
  autoload :Poll,               "#{PARTS}/poll"
  autoload :Fold,               "#{PARTS}/fold"
  autoload :RecordingOutput,    "#{PARTS}/recording_output"
  autoload :Assertions,         "#{PARTS}/assertions"
  autoload :JobSerializer,      "#{PARTS}/job_serializer"
  autoload :TurboHelper,        "#{PARTS}/turbo_helper"

  # Ractors on Ruby 3.4 corrupt the VM's table of call sites: a `super` from Ruby into a C
  # constructor (Data#initialize, say) while Ractors run brings the process down, sometimes
  # minutes later and in unrelated code. Ruby 4.0 has it fixed, and the Ractor::Port API with it
  RACTORS = RUBY_VERSION.split(".").first.to_i >= 4 #: bool

  # Loads every part now rather than on first use - before forking workers, say, so they share
  # the loaded code. TrackedIO is left out when the progressive_io gem is not there, and
  # JobSerializer when ActiveJob is not
  #: () -> singleton(TaskProgress)
  def self.eager_load!
    constants.each do |name|
      const_get(name)
    rescue LoadError
      raise unless OPTIONAL.include?(name)
    end
    self
  end

  OPTIONAL = %i[TrackedIO JobSerializer].freeze #: Array[Symbol]
  private_constant :OPTIONAL

  # Raised at whoever works on a task that was called off, so the work stops at its next step.
  # An Exception rather than a StandardError, like Interrupt: a `rescue => e` around one step
  # should not swallow it and carry on with the next
  class Canceled < Exception # rubocop:disable Lint/InheritException
    # The task that was called off
    attr_reader :task #: TaskProgress

    # For the task that was called off, and what it is called
    #: (TaskProgress, ?String) -> void
    def initialize(task, name = task.name)
      @task = task
      super("Task '#{name}' was canceled")
    end
  end

  # The log the task's tree lives in
  attr_reader :log #: Log
  # The task's place in the tree - `[]` for the root
  attr_reader :path #: path

  ROOT = [] #: path
  ROOT.freeze
  private_constant :ROOT

  # A root reporting wherever suits a command-line program: a parent process, when it handed
  # one down in TASK_PROGRESS_FD; a redrawn tree on a terminal; an ExecutionLog on CI or when
  # piped. With a block, it runs the block as the root's work and returns its value
  #: (?String, ?io: IO | StringIO, ?quiet: bool, **untyped) -> TaskProgress
  #: [T] (?String, ?io: IO | StringIO, ?quiet: bool, **untyped) { (TaskProgress) -> T } -> T?
  def self.cli(name = File.basename($PROGRAM_NAME), io: $stderr, quiet: false, **attributes, &block)
    output = cli_output(io:, quiet:)
    root = new(name, outputs: [output].compact, **attributes)
    if (fd = ENV.delete("TASK_PROGRESS_CONTROL_FD"))
      root.accept_cancel_requests(IO.new(Integer(fd), "r", autoclose: false).tap { it.close_on_exec = true })
    end
    return finish_at_exit(root, output) unless block
    begin
      root.run { block.call(it) }
    ensure
      close(output)
    end
  end

  # The output `cli` and `bar` pick for where the program runs, or nil when `quiet`
  #: (io: IO | StringIO, quiet: bool) -> output?
  def self.cli_output(io:, quiet:)
    if (fd = ENV.delete("TASK_PROGRESS_FD"))
      # Not handed down to a process this one starts, which would hold the pipe open past our exit
      NDJSONOutput.new(IO.new(Integer(fd), "w", autoclose: false).tap { it.close_on_exec = true })
    elsif quiet
      nil
    elsif io.tty? && !ENV["CI"] # some CI runners give a job a terminal, but nobody watches it redraw
      TerminalOutput.new(io)
    else
      ExecutionLogOutput.new(io)
    end
  end

  # A single bar, the way progress bars always worked: no block, and it finishes by itself once
  # its count reaches `total`. Without a total it counts and spins. The last frame is drawn at
  # exit, finished or not
  #
  #     bar = TaskProgress.bar("Importing", total: rows.size)
  #     rows.each { import(it) && bar.tick! }
  #: (?String, ?total: Integer?, ?io: IO | StringIO, ?quiet: bool, **untyped) -> TaskProgress
  def self.bar(name = File.basename($PROGRAM_NAME), total: nil, io: $stderr, quiet: false, **attributes)
    output = cli_output(io:, quiet:)
    root = new(name, outputs: [output].compact, total:, indeterminate: total.nil?, **attributes)
    finish_at_exit(root, output)
  end

  # A root nobody runs a block for is finished when the program ends: done if it ends well,
  # failed with the error if it is going down with one
  #: (TaskProgress, output?) -> TaskProgress
  def self.finish_at_exit(root, output)
    at_exit do
      error = $!
      unless root.finished?
        (error.nil? || (error.is_a?(SystemExit) && error.success?)) ? root.done! : root.fail!(error)
      end
    ensure
      close(output)
    end
    root
  end

  # Outputs that hold a thread or a screen - TerminalOutput, ExecutionLogOutput, BufferedOutput -
  # can be closed, to draw their last and stop
  #: (output?) -> void
  def self.close(output)
    output.close if output.respond_to?(:close) # steep:ignore
  end

  # A bar over a collection, see `bar` and `iterate`
  #
  #     TaskProgress.iterate(rows, "Importing") { |row| import(row) }
  #: (Enumerable[untyped], ?String, ?total: Integer?, ?step: Integer, **untyped) ?{ (untyped) -> untyped } -> untyped
  def self.iterate(collection, name = File.basename($PROGRAM_NAME), total: TaskProgress.size_of(collection), step: 1, **, &block)
    bar(name, total:, **).iterate(collection, step:, &block)
  end

  # A root whose tree is drawn in pages with Turbo, from wherever it runs - a job, say. Every
  # frame is the whole tree as HTML (see HTMLRenderer), sent as a Turbo Stream at most every
  # `interval` seconds, and kept in `store` for a page to draw before the first one arrives.
  # Cancel buttons post to `cancel_url`; the request waits in `store`, where this checks for it
  # every `poll` seconds - so it works across processes too. With a block, the block is the
  # root's work, as with `cli`.
  #
  #     TaskProgress.broadcast(import, "Importing") { |root| ... }   # in a Rails job
  #     <%= task_progress_tree import %>                               # in its page
  #
  # In Rails, the target is a record, and the rest comes from RailsDefaults: Turbo::StreamsChannel,
  # Rails.cache and the route the Railtie adds. Outside Rails the target is the element's id, and
  # `broadcast:` - called with each frame - is up to you
  #: (untyped, ?String, ?broadcast: (^(String) -> void)?, ?store: TurboStreamOutput::_Store?, ?tokens: CancelToken?, ?cancel_url: String?, ?renderer: TurboStreamOutput::_Renderer?, ?interval: Integer | Float, ?poll: Integer | Float, ?expires_in: Integer, **untyped) -> TaskProgress
  #: [T] (untyped, ?String, ?broadcast: (^(String) -> void)?, ?store: TurboStreamOutput::_Store?, ?tokens: CancelToken?, ?cancel_url: String?, ?renderer: TurboStreamOutput::_Renderer?, ?interval: Integer | Float, ?poll: Integer | Float, ?expires_in: Integer, **untyped) { (TaskProgress) -> T } -> T?
  def self.broadcast(target, name = File.basename($PROGRAM_NAME), broadcast: nil, store: nil, tokens: nil, cancel_url: nil, renderer: nil,
    interval: 0.25, poll: 1, expires_in: 86_400, **attributes, &block)
    defaults = RailsDefaults.for(target)
    send = broadcast || defaults[:broadcast] or raise ArgumentError, "Give it broadcast: - outside Rails with turbo-rails, there is nothing to send frames to"
    store ||= defaults[:store]
    tokens ||= defaults[:tokens]
    cancel_url ||= defaults[:cancel_url]
    key = RailsDefaults.key(target)
    renderer ||= HTMLRenderer.new(id: RailsDefaults.id(target), cancel_url: (cancel_url if tokens), cancel_token: tokens&.issue(key, expires_in:))
    output = BufferedOutput.new(TurboStreamOutput.new(renderer:, broadcast: send, store:, key:), interval:)
    root = new(name, outputs: [output], **attributes)
    watch_cancellations(root, store, key, poll) if store && tokens
    return finish_at_exit(root, output) unless block
    begin
      root.run { block.call(it) }
    ensure
      close(output)
    end
  end

  # Picks up the requests CancellationsApp leaves in the store, until the root has ended
  #: (TaskProgress, TurboStreamOutput::_Store, String, Integer | Float) -> Thread
  def self.watch_cancellations(root, store, key, poll) # :nodoc:
    Thread.new do
      Thread.current.report_on_exception = false
      until root.finished?
        sleep(poll)
        root.log.snapshot.each do |path, node|
          next unless node.cancelable && !node.finished?
          request = CancellationsApp.request_key(key, path)
          reason = store.read(request) or next
          store.delete(request)
          root.request_cancel(path, reason.to_s)
        end
      end
    end
  end

  @stream = nil #: untyped
  @stream_lock = Mutex.new #: Thread::Mutex

  # Where `handoff`, `adopt` and `follow` keep trees, unless told otherwise: a MemoryStream for
  # this process alone, until it is set to something every process can reach
  #
  #     TaskProgress.stream = TaskProgress::RedisStream.new(RedisClient.config(url: ENV["REDIS_URL"]).new_pool)
  #: () -> untyped
  def self.stream = @stream || @stream_lock.synchronize { @stream ||= MemoryStream.new }

  # Sets where trees are kept, see `stream`
  #: (untyped) -> void
  def self.stream=(stream)
    @stream = stream
  end

  # A root to hand to whoever does the work - a job, a worker, another machine - which takes it
  # up with `adopt`. Until then it waits, as "pending", where anyone can `follow` it: a page can
  # show the job queued before any worker has picked it up.
  #
  #     import = TaskProgress.handoff("Importing", cancelable: true)
  #     ImportJob.perform_later(upload, import)        # ActiveJob takes the task itself
  #     Importer.perform_async(upload.id, import.key)  # anything else, its key
  #
  # The tree lives in `stream` under `key`. Once it is handed off, leave it to the worker: what
  # this side writes after the worker has started is ignored
  #: (String, ?stream: untyped, **untyped) -> TaskProgress
  def self.handoff(name, stream: self.stream, **attributes)
    key = StreamOutput.key_for(Log.new.id)
    new(name, outputs: [StreamOutput.new(stream, key)], log: Log.new(key:), **attributes)
  end

  # Takes up a tree handed off with `handoff` - by its key, or the task itself - as a root of
  # its own, with the name and attributes it was handed off with. It starts the tree over: a
  # second worker to adopt it, a job retried, replaces what the last one wrote.
  #
  # Batches go out squashed, every `interval` seconds at most. Every `beat` seconds it tells
  # whoever follows that it is alive, and takes the cancel requests that came. With a block,
  # the block is the root's work, see `run`, and it all stops when the block returns. Without
  # one, call `log.close` once the work is over - ActiveJob does this by itself, see JobSerializer
  #: (String | TaskProgress, ?stream: untyped, ?beat: Integer | Float, ?interval: Integer | Float) -> TaskProgress
  #: [T] (String | TaskProgress, ?stream: untyped, ?beat: Integer | Float, ?interval: Integer | Float) { (TaskProgress) -> T } -> T?
  def self.adopt(key, stream: self.stream, beat: 1, interval: 0.1, &block)
    key = key.key || raise(ArgumentError, "#{key.inspect} was not handed off") if key.is_a?(TaskProgress)
    handed = StreamReader.new(stream, key).snapshot&.then { State.fold(it.events)[[]] }
    handed or raise ArgumentError, "Nothing was handed off at #{key}, or it has expired"
    writer = StreamOutput.new(stream, key, beat:)
    output = BufferedOutput.new(writer, interval:)
    log = Log.new(key:)
    log.on_close do
      output.close
      writer.close
    end
    root = new(handed.name, outputs: [output], log:, total: handed.total, expect: handed.expect,
      indeterminate: !!handed.indeterminate, unit: handed.unit, cancelable: !!handed.cancelable, attempt: handed.attempt.to_i + 1)
    return root unless block
    begin
      root.run { block.call(it) }
    ensure
      log.close
    end
  end

  # A tree that mirrors the one in `stream` at `key`, kept up to date on a thread of its own -
  # for drawing it anywhere: a terminal, an SSE or polling endpoint, a parent's tree. Requests
  # to cancel its tasks go to whoever writes it; it goes stale when the writer goes quiet, and
  # fails after `give_up_after` seconds of that, see Mount#follow_stream. Call `log.close` to stop
  # following - SSE and Poll can do it for you when they are done
  #: (String, ?stream: untyped, ?poll: Integer | Float, ?give_up_after: Integer | Float) -> TaskProgress
  def self.follow(key, stream: self.stream, poll: 1, give_up_after: 60)
    root, mount = mirror(key)
    mount.follow_stream(stream, key, poll:, give_up_after:)
    root
  end

  # The tree in `stream` at `key` as it is now, read once - for a page, or one poll, that needs
  # no more than that. See `follow` for one kept up to date
  #: (String, ?stream: untyped) -> TaskProgress
  def self.fetch(key, stream: self.stream)
    root, mount = mirror(key)
    mount.follow_stream(stream, key, watch: false)
    root
  end

  # Runs the block as the work of every root among `arguments` that a worker took up with `adopt`
  # - done when it returns, failed when it raises - and closes them after. What JobSerializer
  # wraps every ActiveJob in; for any other job runner, wrap `perform` in it the same way
  #: [T] (Array[untyped]) { () -> T } -> T?
  def self.working_on(arguments, &block)
    roots = arguments.flat_map { it.is_a?(Hash) ? it.values : [it] }
      .select { it.is_a?(TaskProgress) && it.key && !it.node.sealed } #: Array[TaskProgress]
    begin
      within(roots, &block)
    ensure
      roots.each { it.log.close }
    end
  end

  # The block as the work of each root in turn, the first outermost
  #: [T] (Array[TaskProgress]) { () -> T } -> T?
  def self.within(roots, &block)
    root = roots.first or return block.call
    root.run { within(roots.drop(1), &block) }
  end
  private_class_method :within

  # A root that is a mount and nothing else, named after `key` until the stream says otherwise
  #: (String) -> [TaskProgress, Mount]
  def self.mirror(key)
    log = Log.new(key:)
    root = new(key, log:)
    mount = Mount.new(log, [], own: false)
    log.transaction do |tx|
      tx.journal.touch([], tx.state[[]])
      tx.state[[]]&.sealed = mount
    end
    [root, mount]
  end
  private_class_method :mirror

  # A size that is cheap to know, or nil - never `count`, which would run a lazy enumerator
  #: (untyped) -> Integer?
  def self.size_of(collection) = (collection.size if collection.respond_to?(:size)) # :nodoc:

  # Where the browser client lives: `task_tree.js` (the fold, and `follow` for an SSE stream),
  # `render_queue.js`, `row_view.js`, a Stimulus controller, a React component and
  # `task_tree.css`. No build step - serve the directory as it is, under any prefix
  #: () -> String
  def self.js_path = File.expand_path("../js", __dir__ || ".")

  # A silent root, for a library's default
  #: (?String) -> TaskProgress
  def self.null(name = "progress") = new(name)

  # A new tree, and its root. A block becomes an SummaryOutput - called with `percent:`
  # and `message:` as the tree changes. See `subtask` for `autofinish`. `attempt` says which
  # run of the work this is - from 2 on, it is drawn with the task; `adopt` counts them
  #: (?String, ?outputs: Array[output], ?log: Log, ?total: Integer?, ?expect: Integer?, ?indeterminate: bool, ?unit: String?, ?cancelable: bool, ?autofinish: bool, ?attempt: Integer?) ?{ (percent: Integer, message: String?) -> void } -> void
  def initialize(name = "progress", outputs: [], log: Log.new, total: nil, expect: nil, indeterminate: false, unit: nil, cancelable: false, autofinish: true, attempt: nil, &summary)
    @log = log
    @path = ROOT
    outputs = [*outputs, (SummaryOutput.new { |percent:, message:| summary.call(percent:, message:) } if summary)].compact
    outputs.each { @log.add_output(it) }
    @log.transaction do |tx|
      tx << Event.new(path: [], op: :open, value: TaskProgress.attributes(name:, total:, expect:, indeterminate:, unit:, cancelable:, attempt:))
      tx.state[[]]&.autofinish = autofinish
    end
  end

  # The attributes an `open` carries, without what is at its default
  #: (name: String, ?total: Integer?, ?weight: (Integer | Float)?, ?expect: Integer?, ?indeterminate: bool, ?unit: String?, ?cancelable: bool, ?attempt: Integer?) -> Hash[Symbol, untyped]
  def self.attributes(name:, total: nil, weight: nil, expect: nil, indeterminate: false, unit: nil, cancelable: false, attempt: nil) # :nodoc:
    {name: utf8(name), total:, weight:, expect:, indeterminate: (true if indeterminate), unit:, cancelable: (true if cancelable), attempt:}.compact
  end

  # A handle on the task at `path` in `log`, without opening anything
  #: (Log, path) -> TaskProgress
  def self.handle(log, path) = allocate.tap { it.instance_variable_set(:@log, log); it.instance_variable_set(:@path, path.frozen? ? path : path.dup.freeze) } # :nodoc:

  # The stream key a root from `handoff`, `adopt`, `follow` or `fetch` lives under, which is
  # all it takes to `adopt` or `follow` it from anywhere. Nil for any other task
  #: () -> String?
  def key = (@log.key if @path.empty?)

  # The task and everything under it as plain Hashes - its name, status and percent, and its
  # count, total, message and error where it has them - for a test to compare, or a log line:
  #
  #     {name: "Import", status: :done, percent: 100, children: [
  #       {name: "Rows", status: :failed, percent: 40, count: 4, total: 10, error: "RuntimeError: row 5"}]}
  #: () -> Hash[Symbol, untyped]
  def outline = TaskProgress.outline(@log.snapshot, @path)

  # The node at `path` in `state` as an outline, see TaskProgress#outline
  #: (State, path) -> Hash[Symbol, untyped]
  def self.outline(state, path) # :nodoc:
    node = state[path] or raise ArgumentError, "No task at #{path.inspect}"
    error = node.error
    {
      name: node.name, status: node.status, percent: state.percent(path),
      count: (node.count if node.total || node.count.positive?), total: node.total,
      message: node.message, error: (error && "#{error[:class]}: #{error[:message]}"),
      children: state.children(path).map { outline(state, it) }.then { it unless it.empty? }
    }.compact
  end

  # The task as the tree holds it now - frozen, and safe to read from any thread
  #: () -> Node
  def node = @log.snapshot[@path] || raise(ArgumentError, "No task at #{@path.inspect} - it was pruned")

  # What it is called
  #: () -> String
  def name = node.name

  # `:pending`, `:active`, `:done`, `:failed` or `:canceled`
  #: () -> Symbol
  def status = node.status

  # A whole percent, 100 only once it and everything under it are done
  #: () -> Integer
  def percent = @log.snapshot.percent(@path)

  # How far along, 0.0..1.0, unrounded
  #: () -> Float
  def fraction = @log.snapshot.fraction(@path)

  # The latest thing it said, see `note`
  #: () -> String?
  def message = node.message

  # What it failed with: `class`, `message`, `backtrace` and `cause`, see `fail!`
  #: () -> Hash[Symbol, untyped]?
  def error = node.error

  # How many it has counted, see `advance!`
  #: () -> Integer
  def count = node.count

  # How many it counts to, or nil when it has no total
  #: () -> Integer?
  def total = node.total

  # Done, and everything under it ended
  #: () -> bool
  def done? = @log.snapshot.complete?(@path)

  # Ended by `fail!`
  #: () -> bool
  def failed? = status == :failed

  # Ended by `cancel!`, or by a task above it being canceled
  #: () -> bool
  def canceled? = status == :canceled

  # Whether a reader may offer to call it off, and it has not ended yet
  #: () -> bool
  def cancelable? = !!node.cancelable && !finished?

  # The task at `path` under this one - an Array of ids, or the ids joined with a dash, the way
  # the browser client keys its rows (`x3k0-00af`) - or nil
  #: (path | String) -> TaskProgress?
  def find(path)
    path = path.split("-") if path.is_a?(String)
    full = [*@path, *path]
    TaskProgress.handle(@log, full) if @log.snapshot.key?(full)
  end

  # Ended, by `done!`, `fail!` or `cancel!` - whether or not everything under it did
  #: () -> bool
  def finished? = node.finished?

  # The task it is under, or nil for the root
  #: () -> TaskProgress?
  def parent = (TaskProgress.handle(@log, @path.take(@path.length - 1)) unless @path.empty?)

  # The root of its tree
  #: () -> TaskProgress
  def root = TaskProgress.handle(@log, [])

  # The tasks directly under it, in the order they opened
  #: () -> Array[TaskProgress]
  def subtasks = @log.snapshot.children(@path).map { TaskProgress.handle(@log, it) }

  # Sends this task's subtree to an output, as a tree of its own rooted at `[]` - for the root
  # that is the whole tree. See Log#add_output
  #: (?output?, ?replay: bool) ?{ (Batch, Log) -> void } -> output
  def add_output(output = nil, replay: true, &block) = @log.add_output(output, replay:, path: @path, &block)

  # Stops sending to an output, as it was given to `add_output`
  #: (output) -> void
  def remove_output(output) = @log.remove_output(output)

  # A child task. `total:` makes it counted (drive it with `advance!`), `indeterminate: true`
  # one with no measure of its own, and `weight:` how much of the parent it is. With a block
  # it runs the block as the child's work, see `run`, and returns the block's value.
  #
  # A counted task is done once its count reaches its total. Give it `autofinish: false` when
  # the total is a guess, and the work may go past it.
  #
  # `cancelable: true` tells whoever draws the tree that it may offer to call the task off - see
  # `find` and `cancel!` for taking that request back
  #: (String, ?total: Integer?, ?weight: (Integer | Float)?, ?expect: Integer?, ?indeterminate: bool, ?unit: String?, ?cancelable: bool, ?autofinish: bool) -> TaskProgress
  #: [T] (String, ?total: Integer?, ?weight: (Integer | Float)?, ?expect: Integer?, ?indeterminate: bool, ?unit: String?, ?cancelable: bool, ?autofinish: bool) { (TaskProgress) -> T } -> T?
  def subtask(name, total: nil, weight: nil, expect: nil, indeterminate: false, unit: nil, cancelable: false, autofinish: true, &block)
    child = @log.transaction do |tx|
      writable!(tx)
      path = tx.new_child(@path)
      tx << Event.new(path:, op: :open, value: TaskProgress.attributes(name:, total:, weight:, expect:, indeterminate:, unit:, cancelable:))
      tx.state[path]&.autofinish = autofinish
      TaskProgress.handle(@log, path)
    end
    block ? child.run { block.call(it) } : child
  end

  # Runs the block as this task's work: done when it returns, failed with the error when it
  # raises - an Interrupt or a SignalException included - and the error raised on. A task
  # canceled ends its work quietly: `run` returns nil
  #: [T] () { (TaskProgress) -> T } -> T?
  def run
    result = yield self
    done!
    result
  rescue Canceled => e
    # This task called off - from another thread, say - stops its own work, and nothing above
    # it notices. A task further up called off stops the work in between as well
    return nil if e.task == self
    raise
  rescue Interrupt => e
    cancel!(TaskProgress.interrupted_by(e)) # Ctrl-C calls the work off, it does not fail it
    raise
  rescue Exception => e # rubocop:disable Lint/RescueException
    # Once called off, the work unwinding is no failure - an on_cancel that closed the connection
    # the work was waiting on makes that call raise, and that is the cancel working
    return nil if canceled?
    fail!(e)
    raise
  end

  # Moves the percent; 100 finishes the task
  #: (percent: Integer | Float, ?message: String?) -> self
  def update_to(percent:, message: nil)
    @log.transaction do |tx|
      writable!(tx)
      tx << Event.new(path: @path, op: :note, value: TaskProgress.utf8(message)) if message
      tx << Event.new(path: @path, op: percent == 100 ? :done : :set, value: (percent unless percent == 100))
    end
    self
  end

  # Adds to the count - finishing the task, if that reaches its total
  #: (?Integer, ?message: String?) -> self
  def advance!(by = 1, message: nil)
    @log.transaction do |tx|
      writable!(tx)
      node = tx.state[@path] or next
      total = node.total
      next if node.autofinish && total && node.count >= total && node.status == :done # more work than the total said
      tx << Event.new(path: @path, op: :add, value: by)
      tx << Event.new(path: @path, op: :note, value: TaskProgress.utf8(message)) if message
      tx << Event.new(path: @path, op: :done) if node.autofinish && total && node.count >= total
    end
    self
  end

  # Adds one to the count, see `advance!`
  #: (?message: String?) -> self
  def tick!(message: nil) = advance!(1, message:)

  # Goes through a collection a step per item. Given a name it opens a subtask for it, and
  # otherwise counts on this task. The total comes from `size`, never `count` - so a lazy
  # enumerator stays lazy, and one with no size just counts. Done when the loop ends, failed
  # with the error if the block raises. Without a block it returns an Enumerator, which does
  # the same as it is consumed
  #
  #     root.iterate(files, "Files") { |file| copy(file) }
  #     root.iterate(rows, "Rows").map { transform(it) }
  #: (Enumerable[untyped], ?String?, ?total: Integer?, ?step: Integer) ?{ (untyped) -> untyped } -> untyped
  def iterate(collection, name = nil, total: TaskProgress.size_of(collection), step: 1, &block)
    if name
      task = subtask(name, total:, indeterminate: total.nil?)
    else
      task = self
      meta(total:, indeterminate: false) if total && self.total.nil?
    end
    # Advancing costs a transaction, so it goes in steps of a thousandth of the total - what a
    # bar can show anyway - and a loop over cheap items is not held up by its own progress
    every = total ? [total / 1000, 1].max * step : step
    enumerator = Enumerator.new do |yielder|
      pending = 0
      task.run do
        collection.each do |item|
          yielder << item
          next if (pending += step) < every
          task.advance!(pending)
          pending = 0
        end
      ensure
        task.advance!(pending) if pending.positive? && !task.finished?
      end
    end
    block ? enumerator.each(&block) : enumerator
  end

  # Prints a line above the tree, where it stays. It changes nothing in the tree itself, so a
  # reader joining later never sees it - like anything said on a terminal
  #: (_ToS) -> self
  def puts(message)
    @log.transaction { |tx| writable!(tx) && tx << Event.new(path: @path, op: :say, value: TaskProgress.utf8(message.to_s)) }
    self
  end

  # The latest thing it says, shown on its row
  #: (String?) -> self
  def note(message)
    @log.transaction { |tx| writable!(tx) && tx << Event.new(path: @path, op: :note, value: TaskProgress.utf8(message)) }
    self
  end

  # Changes what it counts to
  #: (Integer?) -> void
  def total=(total)
    meta(total:)
  end

  # Renames it
  #: (String) -> void
  def name=(name)
    meta(name: TaskProgress.utf8(name))
  end

  # Finishes the task, and with it every task under it still open - each with a `done` of its
  # own, deepest first, in the same batch. The work they were part of is over, and a reader
  # should not be left waiting on a task nobody will ever finish. What was mounted is left to
  # its Mount
  #: (?String?) -> self
  def done!(message = nil)
    @log.transaction do |tx|
      next unless writable!(tx, finishing: true)
      tx << Event.new(path: @path, op: :note, value: TaskProgress.utf8(message)) if message
      tx.state.open_under(@path).reverse_each { tx << Event.new(path: it, op: :done) }
      tx << Event.new(path: @path, op: :done)
    end
    self
  end

  # Fails the task with an exception, a message, or nothing. `extra` goes along with the
  # error, booleans and integers only - a reader drops the rest
  #
  # What is still open under it is canceled: it did not fail, it was cut short
  #: (?(Exception | String)?, **bool | Integer) -> self
  def fail!(error = nil, **extra)
    @log.transaction do |tx|
      next unless writable!(tx, finishing: true)
      error = Wire.error_to_h(error || "#{tx.state[@path]&.name} failed").merge(extra)
      tx.state.open_under(@path, mounts: true).reverse_each { tx << Event.new(path: it, op: :cancel) }
      tx << Event.new(path: @path, op: :fail, value: error)
    end
    self
  end

  # Calls the task off, and every task still open under it, each with a `cancel` of its own -
  # from any thread. Whoever works on one of them next gets a Canceled, which `run` takes as
  # the end of that task's work. Canceling a finished task does nothing
  #: (?String?) -> self
  def cancel!(reason = nil)
    @log.transaction { |tx| writable!(tx, finishing: true) && TaskProgress.cancel_in(tx, @path, reason) }
    self
  end

  # Calls the block with the reason once this task is canceled, see Log#on_cancel. For work that
  # blocks and so would not notice a cancel until it next touches its task:
  #
  #     rows.on_cancel { http.finish }
  #: () { (String?) -> void } -> self
  def on_cancel(&block)
    @log.on_cancel(@path, &block)
    self
  end

  # Asks for the task at `path` under this one to be canceled - the way a request from outside
  # (a browser, a parent process) comes in. Everything is decided in one transaction against the
  # tree as it stands, so it cannot race the task finishing. Returns:
  #
  #     :canceled   it was, along with everything still open under it
  #     :forwarded  it lives in a mounted child, which was asked; its cancel comes back up the stream
  #     :moot       there is nothing left to cancel - no such task, or it has already ended
  #     :refused    it is not cancelable
  #
  # A request that comes too late is moot, not an error: by the time it arrives the task may well
  # have finished, and its process exited
  #: (path | String, ?String?) -> Symbol
  def request_cancel(path, reason = nil)
    path = path.split("-") if path.is_a?(String)
    full = [*@path, *path].freeze
    outcome, mount, remote_path = @log.transaction do |tx|
      node = tx.state[full]
      next [:moot, nil, nil] if node.nil? || node.finished?
      next [:refused, nil, nil] unless node.cancelable
      mounted_at = (full.length - 1).downto(0).map { full.take(it) }.find { tx.state[it]&.sealed }
      mount = tx.state[mounted_at]&.sealed if mounted_at
      next [:forwarded, mount, full.drop(mounted_at.length)] if mount && mounted_at
      TaskProgress.cancel_in(tx, full, reason)
      [:canceled, nil, nil]
    end #: [Symbol, Mount?, path?]
    return mount.request_cancel(remote_path, reason) if mount && remote_path
    outcome
  end

  # Reads cancel requests off an IO - one JSON line each, `{"cancel": [ids], "reason": "..."}` -
  # on a thread of its own, and hands them to `request_cancel`. This is the far end of a Mount's
  # control pipe; anything malformed is skipped. Returns the thread, which ends at EOF.
  #
  # The root itself, `[]`, is what the parent mounted, and only the parent asks for it: the
  # mount was ended there, so the root is canceled whether it is cancelable or not
  #: (IO) -> Thread
  def accept_cancel_requests(io)
    Thread.new do
      Thread.current.report_on_exception = false
      io.each_line("\n", Wire::TEXT_LIMIT) { take_cancel_request(it) }
    end
  end

  # Takes one cancel request - a line as `accept_cancel_requests` reads them - and returns what
  # came of it, see `request_cancel`; nil for a line that is not a request
  #: (String) -> Symbol?
  def take_cancel_request(line)
    require "json"
    request = JSON.parse(line) rescue return
    return unless request.is_a?(Hash) && (path = request["cancel"]).is_a?(Array) && path.length <= Wire::MAX_DEPTH
    return unless path.all? { it.is_a?(String) && it.match?(Wire::SEGMENT) }
    return request_cancel(path, Wire.text(request["reason"])) unless path.empty?
    cancel!(Wire.text(request["reason"]))
    :canceled
  rescue ArgumentError
    nil
  end

  # The reason an Interrupt gives, if it gives one: Ctrl-C raises it saying "Interrupt", and a
  # SIGINT from outside saying nothing at all
  #: (Interrupt) -> String?
  def self.interrupted_by(interrupt) = (interrupt.message unless ["", "Interrupt"].include?(interrupt.message)) # :nodoc:

  # Every task called off carries the reason, so each of them can say why it stopped
  #: (Transaction, path, String?) -> void
  def self.cancel_in(tx, path, reason) # :nodoc:
    reason = (utf8(reason.to_s) if reason)
    tx.state.open_under(path, mounts: true).reverse_each { tx << Event.new(path: it, op: :cancel, value: reason) }
    tx << Event.new(path:, op: :cancel, value: reason)
  end

  # Everything the block does to the tree lands as one batch, or none of it does
  #: [T] () { (TaskProgress) -> T } -> T
  def transaction
    @log.transaction { yield self }
  end

  # A child whose subtree is fed from elsewhere - a subprocess, a Ractor, a stream. Only the
  # Mount writes under it, see Mount
  #: (String, ?weight: (Integer | Float)?, ?cancelable: bool) -> Mount
  def mount(name, weight: nil, cancelable: false)
    path = @log.transaction do |tx|
      writable!(tx)
      path = tx.new_child(@path)
      tx << Event.new(path:, op: :open, value: TaskProgress.attributes(name:, weight:, cancelable:))
      # The node holds its Mount, so a cancel request for a task under it can be passed on
      mount = Mount.new(@log, path)
      tx.state[path]&.sealed = mount
      mount
    end
  end

  # Wraps an IO so that reading it advances this task by the bytes read, see TrackedIO. The total
  # is the IO's size unless given; with neither, the task counts bytes with no measure. With a
  # block, the block runs with the wrapped IO as this task's work, see `run`. Needs the
  # progressive_io gem, and an IO that can tell its position - for a pipe or a socket, call
  # `advance!` with each chunk instead
  #: (untyped, ?total: Integer?, ?step: Integer?) -> TrackedIO
  #: [T] (untyped, ?total: Integer?, ?step: Integer?) { (TrackedIO) -> T } -> T?
  def track_io(io, total: nil, step: nil)
    raise ArgumentError, "#{io.class} cannot tell its position, so reading it cannot be tracked - call advance! with each chunk instead" unless positioned?(io)
    total ||= io.size if io.respond_to?(:size)
    meta(total:, unit: "bytes", indeterminate: total.nil?)
    tracked = TrackedIO.new(io, self, total:, step:)
    return tracked unless block_given?
    run { yield(tracked).tap { tracked.flush_progress } } # steep:ignore
  end

  # The same task in the same tree
  #: (untyped) -> bool
  def ==(other) = other.is_a?(TaskProgress) && other.log.equal?(@log) && other.path == @path
  alias_method :eql?, :==

  # Equal handles hash alike, so a task works as a Hash key
  #: () -> Integer
  def hash = [@log.object_id, @path].hash

  # Its path, name and status
  #: () -> String
  def inspect = "#<TaskProgress #{@path.inspect} #{@log.snapshot[@path]&.name.inspect} #{@log.snapshot[@path]&.status}>"

  SCALE = [["TB", 1024**4], ["GB", 1024**3], ["MB", 1024**2], ["KB", 1024]].map(&:freeze).freeze #: Array[[String, Integer]]
  private_constant :SCALE

  # "4.2s", "3m07s", "2h15m"
  #: (Integer | Float) -> String
  def self.duration(seconds)
    if seconds < 60 then format("%.1fs", seconds)
    elsif seconds < 3600 then format("%dm%02ds", seconds / 60, seconds % 60)
    else format("%dh%02dm", seconds / 3600, seconds % 3600 / 60)
    end
  end

  # "142 KB", "2.9 MB", "640 bytes" - a whole number drops its decimal
  #: (Integer | Float) -> String
  def self.human_bytes(n)
    n = n.to_i
    found = SCALE.find { |_, size| n >= size } or return "#{n} bytes"
    unit, size = found
    value = (n.to_f / size).round(1)
    number = (value % 1).zero? ? value.to_i.to_s : format("%.1f", value)
    "#{number} #{unit}"
  end

  # Every message reaches the tree as valid UTF-8. Messages often name files, and a raw
  # ZIP read hands those back tagged ASCII-8BIT, so a "Reading Alice’s.xhtml" would
  # otherwise blow up whatever an output writes to (a database column, a UTF-8 log line)
  #: (nil) -> nil
  #: (untyped) -> String
  def self.utf8(message)
    return if message.nil?
    message = message.to_s
    return message if message.encoding == Encoding::UTF_8 && message.valid_encoding?
    message.dup.force_encoding(Encoding::UTF_8).scrub("�")
  end

  private

  #: (**untyped) -> self
  def meta(**attributes)
    @log.transaction { |tx| writable!(tx) && tx << Event.new(path: @path, op: :meta, value: attributes) }
    self
  end

  # Finishing a finished task is a no-op; anything else on one raises, as does writing under
  # a mount from here
  #: (Transaction, ?finishing: bool) -> bool
  def writable!(tx, finishing: false)
    node = tx.state[@path] or raise ArgumentError, "No task at #{@path.inspect}"
    # Under a mount only the Mount writes - but the mount's own task is the parent's to end
    if sealed?(tx.state) && !(finishing && node.sealed && !sealed?(tx.state, above: true))
      raise ArgumentError, "Task '#{node.name}' is mounted from elsewhere - write to it through its Mount"
    end
    raise Canceled.new(self, node.name) if node.status == :canceled && !finishing
    !(finishing && node.finished?)
  end

  #: (State, ?above: bool) -> bool
  def sealed?(state, above: false) = (0..(above ? @path.length - 1 : @path.length)).any? { state[@path.take(it)]&.sealed }

  #: (untyped) -> bool
  def positioned?(io)
    io.pos
    true
  rescue NoMethodError, Errno::ESPIPE, IOError
    false
  end
end

require_relative "task_progress/railtie" if defined?(::Rails::Railtie)
