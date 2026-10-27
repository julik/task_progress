# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # Redraws the tree in place on a terminal, from a ticker thread of its own so spinners turn
  # while nothing reports. A finished subtree folds into its one line, and when the tree is
  # taller than the screen the finished lines go first, then the ones not started. When the
  # root finishes the tree is drawn one last time and left on screen - or erased, with `erase: true`.
  # A line a task `puts` goes above the tree and stays there
  #
  # With `interval: nil` there is no thread and every batch redraws, which is what tests want
  class TerminalOutput
    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze #: Array[String]
    BAR = 20 #: Integer
    DEFAULT_SIZE = [24, 80].freeze #: [Integer, Integer]
    private_constant :SPINNER, :BAR, :DEFAULT_SIZE

    # @rbs @io: IO | StringIO
    # @rbs @interval: (Integer | Float)?
    # @rbs @erase: bool
    # @rbs @clock: ^() -> Float
    # @rbs @lock: Thread::Mutex
    # @rbs @drawn: Integer
    # @rbs @frame: Integer
    # @rbs @log: Log?
    # @rbs @closed: bool
    # @rbs @ticker: Thread?
    # @rbs @dirty: bool

    # Draws on `io` every `interval` seconds - or on every batch, with `interval: nil`. With `erase: true` the tree is cleared once the root finishes
    #: (?IO | StringIO, ?interval: (Integer | Float)?, ?erase: bool, ?clock: ^() -> Float) -> void
    def initialize(io = $stderr, interval: 0.1, erase: false, clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME) })
      @io = io
      @interval = interval
      @erase = erase
      @clock = clock
      @lock = Mutex.new
      @drawn = 0
      @frame = 0
      @log = nil
      @closed = false
      @ticker = nil
    end

    # Takes one batch, see Log#add_output
    #: (Batch, Log) -> void
    def call(batch, log)
      said = batch.events.filter_map { it.value if it.op == :say } #: Array[String]
      @lock.synchronize do
        @log = log
        return said.each { @io.puts(it) } if @closed
        print_above(said) unless said.empty?
        if log.snapshot[[]]&.finished?
          finish
        elsif @interval.nil? || !said.empty?
          draw
          @ticker ||= Thread.new { tick } if @interval
        else
          @dirty = true
          @ticker ||= Thread.new { tick }
        end
      end
    end

    # Draws the tree one last time and stops the ticker
    #: () -> void
    def close
      @lock.synchronize { finish if @log && !@closed }
      @ticker&.join
    end

    # The lines for a snapshot, without the terminal control around them
    #: (State, ?width: Integer, ?height: Integer) -> Array[String]
    def lines(snapshot, width: columns, height: rows)
      shown = [] #: Array[[path?, Node | Integer]]
      snapshot.each do |path, node|
        next if path.length.positive? && hidden?(snapshot, path)
        shown << [path, node]
      end
      shown = trim(shown, height - 1)
      shown.map { |path, node| line(snapshot, path, node, width) }
    end

    private

    #: () -> void
    def tick
      loop do
        sleep(@interval || 0.1)
        @lock.synchronize do
          return if @closed
          @frame += 1
          draw
        end
      end
    end

    #: () -> void
    def finish
      @closed = true
      @erase ? clear : draw
    end

    #: () -> void
    def draw
      log = @log or return
      text = lines(log.snapshot)
      @io.write("#{up}#{text.join("\n")}\n")
      @io.flush
      @drawn = text.length
    end

    #: (Array[String]) -> void
    def print_above(said)
      @io.write("#{up}#{said.join("\n")}\n")
      @drawn = 0
    end

    #: () -> void
    def clear
      @io.write(up)
      @io.flush
      @drawn = 0
    end

    #: () -> String
    def up = @drawn.zero? ? "" : "\e[#{@drawn}A\e[J"

    # Under a finished node only what failed shows, so a failure leaves the way down to it
    #: (State, path) -> bool
    def hidden?(snapshot, path)
      (0...path.length).any? { snapshot[path.take(it)]&.finished? && snapshot[path.take(it + 1)]&.status != :failed }
    end

    # What fits in `room` lines - the last of them saying how many more there are
    #: (Array[[path?, Node | Integer]], Integer) -> Array[[path?, Node | Integer]]
    def trim(shown, room)
      room = [room, 2].max
      %i[done pending].each do |status|
        break if shown.length <= room
        excess = shown.length - room
        shown = shown.each_with_index.reject { |(_, node), i| i.positive? && node.is_a?(Node) && node.status == status && (excess -= 1) >= 0 }.map(&:first)
      end
      return shown if shown.length <= room
      more = [nil, shown.length - room + 1] #: [path?, Node | Integer]
      shown.first(room - 1) + [more]
    end

    #: (State, path?, Node | Integer, Integer) -> String
    def line(snapshot, path, node, width)
      return "  … #{node} more" if path.nil? || node.is_a?(Integer)
      indent = "  " * path.length
      parts = ["#{indent}#{icon(node)} #{node.name}"] #: Array[String?]
      parts << measure(snapshot, path, node)
      parts << pace(node) if node.status == :active && node.children.empty?
      parts << elapsed(node)
      parts << (node.status == :failed ? node.error&.dig(:message) : node.message)
      parts.compact.reject(&:empty?).join("  ")[0, width - 1].to_s
    end

    #: (Node) -> String
    def icon(node)
      case node.status
      when :done then "✓"
      when :failed then "✗"
      when :canceled then "⊘"
      when :pending then "·"
      else node.stale ? "?" : SPINNER.fetch(@frame % SPINNER.length)
      end
    end

    #: (State, path, Node) -> String?
    def measure(snapshot, path, node)
      return nil if node.status == :done && path.length.positive?
      percent = snapshot.percent(path)
      if node.children.empty? && node.indeterminate
        (node.unit == "bytes") ? TaskProgress.human_bytes(node.count) : node.count.to_s if node.count.positive?
      elsif node.children.empty? && (total = node.total)
        count = (node.unit == "bytes") ? "#{TaskProgress.human_bytes(node.count)} / #{TaskProgress.human_bytes(total)}" : "#{node.count}/#{total}"
        "#{bar(percent)} #{count}"
      else
        format("%s %3d%%", bar(percent), percent)
      end
    end

    #: (Integer) -> String
    def bar(percent)
      filled = BAR * percent / 100
      "#{"█" * filled}#{"░" * (BAR - filled)}"
    end

    # The rate over the whole run so far, and the time left at that rate. Steadier than a
    # rate over the last few ticks, which jumps about with every pause in the work
    #: (Node) -> String?
    def pace(node)
      started = node.started_at or return nil
      seconds = @clock.call - started
      return nil unless seconds >= 1 && node.count.positive?
      rate = node.count / seconds
      per = (node.unit == "bytes") ? "#{TaskProgress.human_bytes(rate)}/s" : format((rate < 10) ? "%.1f/s" : "%d/s", rate)
      total = node.total
      return per unless total && total > node.count
      "#{per}  ETA #{TaskProgress.duration((total - node.count) / rate)}"
    end

    #: (Node) -> String?
    def elapsed(node)
      started = node.started_at or return nil
      TaskProgress.duration((node.finished_at || @clock.call) - started)
    end

    #: () -> Integer
    def columns = size[1]

    #: () -> Integer
    def rows = size[0]

    #: () -> [Integer, Integer]
    def size
      io = @io
      return DEFAULT_SIZE unless io.is_a?(IO) # a StringIO has no screen
      require "io/console"
      rows, cols = io.winsize
      (rows.positive? && cols.positive?) ? [rows, cols] : DEFAULT_SIZE
    rescue NoMethodError, SystemCallError
      DEFAULT_SIZE
    end
  end
end
