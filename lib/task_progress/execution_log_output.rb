# frozen_string_literal: true

class TaskProgress
  # For a CI log, or anything else that is read top to bottom after the fact: one finished
  # line per thing worth saying, never a redraw, each line led by the overall percent and
  # the time since the root opened.
  #
  #   [ 42%  1m02s] Import › Rows: row 12000
  #   [ 50%  1m10s] ✓ Import › Rows  8.1s
  #   [ 50%  1m11s] ✗ Import › Engine: watermarking failed
  #   [ 50%  1m12s] ⊘ Import › Publish: Ctrl-C
  #
  # A task finishing, failing or being canceled, and a line it `puts`, go out at once and every
  # time - though of a task and the ones under it ending in one batch, only the task says so. The
  # rest - notes and counts - are only ever the latest news, so it says at most one of those
  # per `interval`, the newest. With nothing to say for `heartbeat` it says it is still
  # going, so a CI runner watching for output does not take a long quiet step for a hang
  class ExecutionLogOutput
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
    end

    def call(batch, log)
      @lock.synchronize do
        return if @closed
        @log = log
        @said_at = @clock.call - @interval if @said_at.infinite? # the first news goes out at once
        snapshot = log.snapshot
        endings = batch.events.filter_map { it.path if ENDINGS.include?(it.op) }
        batch.events.each do |event|
          case event.op
          when *ENDINGS
            # News from inside a task that has ended is old news
            @pending = nil if @pending && @pending.first[0, event.path.length] == event.path
            next if endings.any? { it.length < event.path.length && event.path[0, it.length] == it }
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
    def close
      @lock.synchronize { close_locked }
      @thread&.join
    end

    private

    def run
      @lock.synchronize do
        until @closed
          due = @pending ? @said_at + @interval : @said_at + @heartbeat
          wait = due - @clock.call
          next @wake.wait(@lock, wait) if wait.positive?
          @pending ? say_pending : say(@log.snapshot, "#{@log.snapshot[[]]&.name}: still going")
        end
      end
    end

    def close_locked(flush: true)
      return if @closed
      say_pending if flush && @pending && @log
      @closed = true
      @wake.signal
    end

    def say_pending
      path, message = @pending
      @pending = nil
      snapshot = @log.snapshot
      node = snapshot[path] or return
      say(snapshot, message ? "#{names(snapshot, path)}: #{message}" : "#{names(snapshot, path)}#{count(node)}")
    end

    def say(snapshot, text)
      root = snapshot[[]]
      elapsed = root ? @clock.call - root.opened_at : 0
      @io.puts(format("[%3d%% %6s] %s", snapshot.percent, TaskProgress.duration(elapsed), text))
      @io.flush
      @said_at = @clock.call
    end

    ENDINGS = %i[done fail cancel].freeze

    def ending(snapshot, event)
      names = names(snapshot, event.path)
      case event.op
      when :done then "✓ #{names}#{took(snapshot[event.path])}"
      when :fail then "✗ #{names}: #{event.value&.dig(:message)}"
      else "⊘ #{names}#{": #{event.value}" if event.value}"
      end
    end

    def names(snapshot, path) = (0..path.length).filter_map { snapshot[path[0, it]]&.name }.join(" › ")

    def count(node)
      return "" unless node.total || node.count.positive?
      bytes = node.unit == "bytes"
      shown = bytes ? TaskProgress.human_bytes(node.count) : node.count.to_s
      total = (bytes ? TaskProgress.human_bytes(node.total) : node.total.to_s) if node.total
      " #{[shown, total].compact.join("/")}"
    end

    # A task that reported nothing before it finished started when it finished, as far as the
    # tree knows - so it took as long as it was open
    def took(node)
      return "" unless node&.finished_at
      from = (node.started_at && node.started_at < node.finished_at) ? node.started_at : node.opened_at
      "  #{TaskProgress.duration(node.finished_at - from)}"
    end
  end
end
