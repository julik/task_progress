# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # For a CI log, or anything else that is read top to bottom after the fact: one finished
  # line per thing worth saying, never a redraw, each line led by the overall percent and
  # the time since the root opened.
  #
  #     [ 42%  1m02s] Import › Rows: row 12000
  #     [ 50%  1m10s] ✓ Import › Rows  8.1s
  #     [ 50%  1m11s] ✗ Import › Engine: watermarking failed
  #     [ 50%  1m12s] ⊘ Import › Publish: Ctrl-C
  #
  # A task finishing, failing or being canceled, and a line it `puts`, go out at once and every
  # time - though of a task and the ones under it ending in one batch, only the task says so. The
  # rest - notes and counts - are only ever the latest news, so it says at most one of those
  # per `interval`, the newest. With nothing to say for `heartbeat` it says it is still
  # going, so a CI runner watching for output does not take a long quiet step for a hang
  class ExecutionLogOutput
    # @rbs @io: IO | StringIO
    # @rbs @interval: Integer | Float
    # @rbs @heartbeat: Integer | Float
    # @rbs @clock: ^() -> Float
    # @rbs @lock: Thread::Mutex
    # @rbs @wake: Thread::ConditionVariable
    # @rbs @log: Log?
    # @rbs @pending: [path, String?]?
    # @rbs @said_at: Float
    # @rbs @closed: bool
    # @rbs @thread: Thread?
    # @rbs @ended: Set[path]

    # Writes to `io`: news at most every `interval` seconds, and that it is still going after `heartbeat` seconds of quiet
    #: (?IO | StringIO, ?interval: Integer | Float, ?heartbeat: Integer | Float, ?clock: ^() -> Float) -> void
    def initialize(io = $stderr, interval: 3.0, heartbeat: 60.0, clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME) })
      @io = io
      @interval = interval
      @heartbeat = heartbeat
      @clock = clock
      @lock = Mutex.new
      @wake = ConditionVariable.new
      @log = nil
      @pending = nil
      @said_at = -Float::INFINITY
      @closed = false
      @thread = nil
      @ended = Set.new
    end

    # Takes one batch, see Log#add_output
    #: (Batch, Log) -> void
    def call(batch, log)
      @lock.synchronize do
        return if @closed
        @log = log
        @said_at = @clock.call - @interval if @said_at.infinite? # the first news goes out at once
        snapshot = log.snapshot
        events = batch.events.map { ending_put(it) || it }
        endings = events.filter_map { it.path if ENDINGS.include?(it.op) }
        events.each do |event|
          case event.op
          when *ENDINGS
            # News from inside a task that has ended is old news
            @pending = nil if @pending&.first&.take(event.path.length) == event.path
            next unless @ended.add?(event.path)
            next if endings.any? { it.length < event.path.length && event.path.take(it.length) == it }
            say(snapshot, ending(snapshot, event))
          when :say then say(snapshot, "#{names(snapshot, event.path)}: #{event.value}")
          when :note then @pending = [event.path, event.value] if event.value
          when :set, :add then @pending = [event.path, nil] unless @pending&.first == event.path
          end
        end
        return close_locked(flush: false) if snapshot[[]]&.finished? # older news than the ending
        say_pending if @pending && @clock.call - @said_at >= @interval
        @thread ||= Thread.new { run }
        @wake.signal
      end
    end

    # Says what is still pending, and stops
    #: () -> void
    def close
      @lock.synchronize { close_locked }
      @thread&.join
    end

    private

    #: () -> void
    def run
      @lock.synchronize do
        until @closed
          due = @pending ? @said_at + @interval : @said_at + @heartbeat
          wait = due - @clock.call
          next @wake.wait(@lock, wait) if wait.positive?
          next say_pending if @pending
          snapshot = @log&.snapshot or next
          say(snapshot, "#{snapshot[[]]&.name}: still going")
        end
      end
    end

    #: (?flush: bool) -> void
    def close_locked(flush: true)
      return if @closed
      say_pending if flush && @pending && @log
      @closed = true
      @wake.signal
    end

    #: () -> void
    def say_pending
      pending = @pending or return
      path, message = pending
      @pending = nil
      snapshot = @log&.snapshot or return
      node = snapshot[path] or return
      say(snapshot, message ? "#{names(snapshot, path)}: #{message}" : "#{names(snapshot, path)}#{count(node)}")
    end

    #: (State, String) -> void
    def say(snapshot, text)
      root = snapshot[[]]
      elapsed = root ? @clock.call - root.opened_at : 0
      @io.puts(format("[%3d%% %6s] %s", snapshot.percent, TaskProgress.duration(elapsed), text))
      @io.flush
      @said_at = @clock.call
    end

    ENDINGS = %i[done fail cancel].freeze #: Array[Symbol]
    PUT_ENDINGS = {done: :done, failed: :fail, canceled: :cancel}.freeze #: Hash[Symbol, Symbol]
    private_constant :ENDINGS, :PUT_ENDINGS

    # A squashed batch - from BufferedOutput, a stream, a mount catching up - says a task ended by
    # putting it whole, finished. Said once, like the ending it stands for
    #: (Event) -> Event?
    def ending_put(event)
      op = PUT_ENDINGS[event.value[:status]] if event.op == :put
      return unless op && !@ended.include?(event.path)
      Event.new(path: event.path, op:, value: (op == :fail) ? event.value[:error] : ((op == :cancel) ? event.value[:message] : nil))
    end

    #: (State, Event) -> String
    def ending(snapshot, event)
      names = names(snapshot, event.path)
      case event.op
      when :done then "✓ #{names}#{took(snapshot[event.path])}"
      when :fail then "✗ #{names}: #{event.value&.dig(:message)}"
      else "⊘ #{names}#{": #{event.value}" if event.value}"
      end
    end

    # The task's name, after the names of every task it is under
    #: (State, path) -> String
    def names(snapshot, path) = (0..path.length).filter_map { snapshot[path.take(it)]&.name }.join(" › ")

    #: (Node) -> String
    def count(node)
      total = node.total
      return "" unless total || node.count.positive?
      bytes = node.unit == "bytes"
      shown = bytes ? TaskProgress.human_bytes(node.count) : node.count.to_s
      total = (bytes ? TaskProgress.human_bytes(total) : total.to_s) if total
      " #{[shown, total].compact.join("/")}"
    end

    # A task that reported nothing before it finished started when it finished, as far as the
    # tree knows - so it took as long as it was open
    #: (Node?) -> String
    def took(node)
      return "" unless node && (finished = node.finished_at)
      started = node.started_at
      from = (started && started < finished) ? started : node.opened_at
      "  #{TaskProgress.duration(finished - from)}"
    end
  end
end
