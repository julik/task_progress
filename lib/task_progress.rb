# frozen_string_literal: true

require_relative "task_progress/version"
require_relative "task_progress/event"
require_relative "task_progress/state"
require_relative "task_progress/wire"
require_relative "task_progress/log"
require_relative "task_progress/branch"
require_relative "task_progress/mount"
require_relative "task_progress/outputs"
require_relative "task_progress/sse"
require_relative "task_progress/refinements"

# Hierarchical progress for task trees. A TaskProgress is a handle onto one node of a tree; the
# tree itself is a Log of change events, applied and numbered under one lock, which outputs
# receive in order - to draw a terminal, write to a pipe, stream to a browser, or feed a Mount
# that grafts the tree under a node of a tree in another process.
#
#   TaskProgress.cli("Import") do |root|
#     root.subtask("Download", unit: "bytes") { |t| t.track_io(io) ... }
#     root.subtask("Rows", total: rows.size) { |t| rows.each { import(it); t.tick! } }
#   end
class TaskProgress
  # Raised at whoever works on a task that was called off, so the work stops at its next step.
  # An Exception rather than a StandardError, like Interrupt: a `rescue => e` around one step
  # should not swallow it and carry on with the next
  class Canceled < Exception # rubocop:disable Lint/InheritException
    attr_reader :task

    def initialize(task, name)
      @task = task
      super("Task '#{name}' was canceled")
    end
  end

  attr_reader :log, :path

  # A root reporting wherever suits a command-line program: a parent process, when it handed
  # one down in TASK_PROGRESS_FD; a redrawn tree on a terminal; an ExecutionLog on CI or when
  # piped. With a block, it runs the block as the root's work and returns its value
  def self.cli(name = File.basename($PROGRAM_NAME), io: $stderr, quiet: false, **attributes, &block)
    output = cli_output(io:, quiet:)
    root = new(name, outputs: [output].compact, **attributes)
    return finish_at_exit(root, output) unless block
    begin
      root.run(&block)
    ensure
      output.close if output.respond_to?(:close)
    end
  end

  def self.cli_output(io:, quiet:)
    if (fd = ENV.delete("TASK_PROGRESS_FD"))
      Outputs::NDJSON.new(IO.new(Integer(fd), "w", autoclose: false))
    elsif quiet
      nil
    elsif io.tty? && !ENV["CI"] # some CI runners give a job a terminal, but nobody watches it redraw
      Outputs::Terminal.new(io)
    else
      Outputs::ExecutionLog.new(io)
    end
  end

  # A single bar, the way progress bars always worked: no block, and it finishes by itself once
  # its count reaches `total`. Without a total it counts and spins. The last frame is drawn at
  # exit, finished or not
  #
  #   bar = TaskProgress.bar("Importing", total: rows.size)
  #   rows.each { import(it) && bar.tick! }
  def self.bar(name = File.basename($PROGRAM_NAME), total: nil, io: $stderr, quiet: false, **attributes)
    output = cli_output(io:, quiet:)
    root = new(name, outputs: [output].compact, total:, indeterminate: total.nil?, **attributes)
    finish_at_exit(root, output)
  end

  # A root nobody runs a block for is finished when the program ends: done if it ends well,
  # failed with the error if it is going down with one
  def self.finish_at_exit(root, output)
    at_exit do
      error = $!
      unless root.finished?
        (error.nil? || (error.is_a?(SystemExit) && error.success?)) ? root.done! : root.fail!(error)
      end
    ensure
      output.close if output.respond_to?(:close)
    end
    root
  end

  # A bar over a collection, see `bar` and `iterate`
  #
  #   TaskProgress.iterate(rows, "Importing") { |row| import(row) }
  def self.iterate(collection, name = File.basename($PROGRAM_NAME), total: TaskProgress.size_of(collection), step: 1, **, &block)
    bar(name, total:, **).iterate(collection, step:, &block)
  end

  # A size that is cheap to know, or nil - never `count`, which would run a lazy enumerator
  def self.size_of(collection) = (collection.size if collection.respond_to?(:size))

  # Where the browser client lives: `task_tree.js` (the fold, and `follow` for an SSE stream),
  # `render_queue.js`, `row_view.js`, a Stimulus controller, a React component and
  # `task_tree.css`. No build step - serve the directory as it is, under any prefix
  def self.js_path = File.expand_path("../js", __dir__)

  # A silent root, for a library's default
  def self.null(name = "progress") = new(name)

  # A new tree, and its root. A block becomes an Outputs::Summary - called with `percent:`
  # and `message:` as the tree changes. See `subtask` for `autofinish`
  def initialize(name = "progress", outputs: [], log: Log.new, total: nil, expect: nil, indeterminate: false, unit: nil, cancelable: false, autofinish: true, &summary)
    @log = log
    @path = [].freeze
    [*outputs, (Outputs::Summary.new(&summary) if summary)].compact.each { @log.add_output(it) }
    @log.transaction do |tx|
      tx << Event.new(path: [], op: :open, value: TaskProgress.attributes(name:, total:, expect:, indeterminate:, unit:, cancelable:))
      tx.state[[]].autofinish = autofinish
    end
  end

  def self.attributes(name:, total: nil, weight: nil, expect: nil, indeterminate: false, unit: nil, cancelable: false)
    {name: utf8(name), total:, weight:, expect:, indeterminate: (true if indeterminate), unit:, cancelable: (true if cancelable)}.compact
  end

  def self.handle(log, path) = allocate.tap { it.instance_variable_set(:@log, log); it.instance_variable_set(:@path, path.frozen? ? path : path.dup.freeze) }

  def node = @log.snapshot[@path]

  def name = node.name

  def status = node.status

  def percent = @log.snapshot.percent(@path)

  def fraction = @log.snapshot.fraction(@path)

  def message = node.message

  def error = node.error

  def count = node.count

  def total = node.total

  def done? = @log.snapshot.complete?(@path)

  def failed? = status == :failed

  def canceled? = status == :canceled

  # Whether a reader may offer to call it off, and it has not ended yet
  def cancelable? = !!node.cancelable && !finished?

  # The task at `path` under this one - an Array of ids, or the ids joined with "/" the way the
  # browser client keys its rows - or nil
  def find(path)
    path = path.split("/") if path.is_a?(String)
    full = [*@path, *path]
    TaskProgress.handle(@log, full) if @log.snapshot.key?(full)
  end

  # Ended, by `done!` or `fail!` - whether or not everything under it did
  def finished? = node.finished?

  def parent = (TaskProgress.handle(@log, @path[0...-1]) unless @path.empty?)

  def root = TaskProgress.handle(@log, [])

  def subtasks = @log.snapshot.children(@path).map { TaskProgress.handle(@log, it) }

  # Sends this task's subtree to an output, as a tree of its own rooted at `[]` - for the root
  # that is the whole tree. See Log#add_output
  def add_output(output = nil, replay: true, &block) = @log.add_output(output, replay:, path: @path, &block)

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
  def subtask(name, total: nil, weight: nil, expect: nil, indeterminate: false, unit: nil, cancelable: false, autofinish: true, &block)
    child = @log.transaction do |tx|
      writable!(tx)
      path = tx.new_child(@path)
      tx << Event.new(path:, op: :open, value: TaskProgress.attributes(name:, total:, weight:, expect:, indeterminate:, unit:, cancelable:))
      tx.state[path].autofinish = autofinish
      TaskProgress.handle(@log, path)
    end
    block ? child.run(&block) : child
  end

  # Runs the block as this task's work: done when it returns, failed with the error when it
  # raises - an Interrupt or a SignalException included - and the error raised on
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
    cancel!(e.message == "Interrupt" ? nil : e.message) # Ctrl-C calls the work off, it does not fail it
    raise
  rescue Exception => e # rubocop:disable Lint/RescueException
    fail!(e)
    raise
  end

  # Moves the percent; 100 finishes the task
  def update_to(percent:, message: nil)
    @log.transaction do |tx|
      writable!(tx)
      tx << Event.new(path: @path, op: :note, value: TaskProgress.utf8(message)) if message
      tx << Event.new(path: @path, op: percent == 100 ? :done : :set, value: (percent unless percent == 100))
    end
    self
  end

  def advance!(by = 1, message: nil)
    @log.transaction do |tx|
      writable!(tx)
      node = tx.state[@path]
      next if node.autofinish && node.total && node.count >= node.total && node.status == :done # more work than the total said
      tx << Event.new(path: @path, op: :add, value: by)
      tx << Event.new(path: @path, op: :note, value: TaskProgress.utf8(message)) if message
      tx << Event.new(path: @path, op: :done) if node.autofinish && node.total && node.count >= node.total
    end
    self
  end

  def tick!(message: nil) = advance!(1, message:)

  # Goes through a collection a step per item. Given a name it opens a subtask for it, and
  # otherwise counts on this task. The total comes from `size`, never `count` - so a lazy
  # enumerator stays lazy, and one with no size just counts. Done when the loop ends, failed
  # with the error if the block raises. Without a block it returns an Enumerator, which does
  # the same as it is consumed
  #
  #   root.iterate(files, "Files") { |file| copy(file) }
  #   root.iterate(rows, "Rows").map { transform(it) }
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
  def puts(message)
    @log.transaction { |tx| writable!(tx) && tx << Event.new(path: @path, op: :say, value: TaskProgress.utf8(message.to_s)) }
    self
  end

  def note(message)
    @log.transaction { |tx| writable!(tx) && tx << Event.new(path: @path, op: :note, value: TaskProgress.utf8(message)) }
    self
  end

  def total=(total)
    meta(total:)
  end

  def name=(name)
    meta(name: TaskProgress.utf8(name))
  end

  # Finishes the task, and with it every task under it still open - each with a `done` of its
  # own, deepest first, in the same batch. The work they were part of is over, and a reader
  # should not be left waiting on a task nobody will ever finish. What was mounted is left to
  # its Mount
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
  def fail!(error = nil, **extra)
    @log.transaction do |tx|
      next unless writable!(tx, finishing: true)
      error = Wire.error_to_h(error || "#{tx.state[@path].name} failed").merge(extra)
      tx.state.open_under(@path, mounts: true).reverse_each { tx << Event.new(path: it, op: :cancel) }
      tx << Event.new(path: @path, op: :fail, value: error)
    end
    self
  end

  # Calls the task off, and every task still open under it, each with a `cancel` of its own -
  # from any thread. Whoever works on one of them next gets a Canceled, which `run` takes as
  # the end of that task's work. Canceling a finished task does nothing
  def cancel!(reason = nil)
    @log.transaction do |tx|
      next unless writable!(tx, finishing: true)
      tx.state.open_under(@path, mounts: true).reverse_each { tx << Event.new(path: it, op: :cancel) }
      tx << Event.new(path: @path, op: :cancel, value: (TaskProgress.utf8(reason.to_s) if reason))
    end
    self
  end

  # Everything the block does to the tree lands as one batch, or none of it does
  def transaction
    @log.transaction { yield self }
  end

  # A child whose subtree is fed from elsewhere - a subprocess, a Ractor, a stream. Only the
  # Mount writes under it, see Mount
  def mount(name, weight: nil, cancelable: false)
    path = @log.transaction do |tx|
      writable!(tx)
      path = tx.new_child(@path)
      tx << Event.new(path:, op: :open, value: TaskProgress.attributes(name:, weight:, cancelable:))
      tx.state[path].sealed = true
      path
    end
    Mount.new(@log, path)
  end

  # Wraps an IO so that reading it advances this task by the bytes read, see TrackedIO. The total
  # is the IO's size unless given; with neither, the task counts bytes with no measure. With a
  # block, the block runs with the wrapped IO as this task's work, see `run`. Needs the
  # progressive_io gem, and an IO that can tell its position - for a pipe or a socket, call
  # `advance!` with each chunk instead
  def track_io(io, total: nil, step: nil)
    require_relative "task_progress/tracked_io"
    raise ArgumentError, "#{io.class} cannot tell its position, so reading it cannot be tracked - call advance! with each chunk instead" unless positioned?(io)
    total ||= io.size if io.respond_to?(:size)
    meta(total:, unit: "bytes", indeterminate: total.nil?)
    tracked = TrackedIO.new(io, self, total:, step:)
    return tracked unless block_given?
    run { yield(tracked).tap { tracked.flush_progress } }
  end

  def ==(other) = other.is_a?(TaskProgress) && other.log.equal?(@log) && other.path == @path
  alias_method :eql?, :==

  def hash = [@log.object_id, @path].hash

  def inspect = "#<TaskProgress #{@path.inspect} #{node&.name.inspect} #{node&.status}>"

  SCALE = [["TB", 1024**4], ["GB", 1024**3], ["MB", 1024**2], ["KB", 1024]].map(&:freeze).freeze

  # "142 KB", "2.9 MB", "640 bytes" - a whole number drops its decimal
  def self.duration(seconds)
    if seconds < 60 then format("%.1fs", seconds)
    elsif seconds < 3600 then format("%dm%02ds", seconds / 60, seconds % 60)
    else format("%dh%02dm", seconds / 3600, seconds % 3600 / 60)
    end
  end

  def self.human_bytes(n)
    n = n.to_i
    unit, size = SCALE.find { |_, size| n >= size }
    return "#{n} bytes" if unit.nil?
    value = (n.to_f / size).round(1)
    number = (value % 1).zero? ? value.to_i.to_s : format("%.1f", value)
    "#{number} #{unit}"
  end

  # Every message reaches the tree as valid UTF-8. Messages often name files, and a raw
  # ZIP read hands those back tagged ASCII-8BIT, so a "Reading Alice’s.xhtml" would
  # otherwise blow up whatever an output writes to (a database column, a UTF-8 log line)
  def self.utf8(message)
    return if message.nil?
    message = message.to_s
    return message if message.encoding == Encoding::UTF_8 && message.valid_encoding?
    message.dup.force_encoding(Encoding::UTF_8).scrub("�")
  end

  private

  def meta(**attributes)
    @log.transaction { |tx| writable!(tx) && tx << Event.new(path: @path, op: :meta, value: attributes) }
    self
  end

  # Finishing a finished task is a no-op; anything else on one raises, as does writing under
  # a mount from here
  def writable!(tx, finishing: false)
    node = tx.state[@path] or raise ArgumentError, "No task at #{@path.inspect}"
    # Under a mount only the Mount writes - but the mount's own task is the parent's to end
    if sealed?(tx.state) && !(finishing && node.sealed && !sealed?(tx.state, above: true))
      raise ArgumentError, "Task '#{node.name}' is mounted from elsewhere - write to it through its Mount"
    end
    raise Canceled.new(self, node.name) if node.status == :canceled && !finishing
    !(finishing && node.finished?)
  end

  def sealed?(state, above: false) = (0..(above ? @path.length - 1 : @path.length)).any? { state[@path[0, it]]&.sealed }

  def positioned?(io)
    io.pos
    true
  rescue NoMethodError, Errno::ESPIPE, IOError
    false
  end
end
