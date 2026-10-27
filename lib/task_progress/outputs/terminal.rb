# frozen_string_literal: true

class TaskProgress
  module Outputs
    # Redraws the tree in place on a terminal, from a ticker thread of its own so spinners turn
    # while nothing reports. A finished subtree folds into its one line, and when the tree is
    # taller than the screen the finished lines go first, then the ones not started. When the
    # root finishes the tree is drawn one last time and left on screen - or erased, with `erase: true`.
    # A line a task `puts` goes above the tree and stays there
    #
    # With `interval: nil` there is no thread and every batch redraws, which is what tests want
    class Terminal
      SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
      BAR = 20
      DEFAULT_SIZE = [24, 80].freeze

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

      def call(batch, log)
        said = batch.events.filter_map { it.value if it.op == :say }
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

      def close
        @lock.synchronize { finish if @log && !@closed }
        @ticker&.join
      end

      # The lines for a snapshot, without the terminal control around them
      def lines(snapshot, width: columns, height: rows)
        shown = []
        snapshot.each do |path, node|
          next if path.length.positive? && hidden?(snapshot, path)
          shown << [path, node]
        end
        shown = trim(shown, height - 1)
        shown.map { |path, node| line(snapshot, path, node, width) }
      end

      private

      def tick
        loop do
          sleep(@interval)
          @lock.synchronize do
            return if @closed
            @frame += 1
            draw
          end
        end
      end

      def finish
        @closed = true
        @erase ? clear : draw
      end

      def draw
        text = lines(@log.snapshot)
        @io.write("#{up}#{text.join("\n")}\n")
        @io.flush
        @drawn = text.length
      end

      def print_above(said)
        @io.write("#{up}#{said.join("\n")}\n")
        @drawn = 0
      end

      def clear
        @io.write(up)
        @io.flush
        @drawn = 0
      end

      def up = @drawn.zero? ? "" : "\e[#{@drawn}A\e[J"

      # Under a finished node only what failed shows, so a failure leaves the way down to it
      def hidden?(snapshot, path)
        (0...path.length).any? { snapshot[path[0, it]].finished? && snapshot[path[0, it + 1]].status != :failed }
      end

      def trim(shown, room)
        room = [room, 2].max
        %i[done pending].each do |status|
          break if shown.length <= room
          excess = shown.length - room
          shown = shown.each_with_index.reject { |(_, node), i| i.positive? && node.status == status && (excess -= 1) >= 0 }.map(&:first)
        end
        return shown if shown.length <= room
        shown.first(room - 1) + [[nil, shown.length - room + 1]]
      end

      def line(snapshot, path, node, width)
        return "  … #{node} more" if path.nil?
        indent = "  " * path.length
        parts = ["#{indent}#{icon(node)} #{node.name}"]
        parts << measure(snapshot, path, node)
        parts << pace(node) if node.status == :active && node.children.empty?
        parts << elapsed(node)
        parts << (node.status == :failed ? node.error&.dig(:message) : node.message)
        parts.compact.reject(&:empty?).join("  ")[0, width - 1]
      end

      def icon(node)
        case node.status
        when :done then "✓"
        when :failed then "✗"
        when :pending then "·"
        else node.stale ? "?" : SPINNER[@frame % SPINNER.length]
        end
      end

      def measure(snapshot, path, node)
        return nil if node.status == :done && path.length.positive?
        percent = snapshot.percent(path)
        if node.children.empty? && node.indeterminate
          (node.unit == "bytes") ? TaskProgress.human_bytes(node.count) : node.count.to_s if node.count.positive?
        elsif node.children.empty? && node.total
          count = (node.unit == "bytes") ? "#{TaskProgress.human_bytes(node.count)} / #{TaskProgress.human_bytes(node.total)}" : "#{node.count}/#{node.total}"
          "#{bar(percent)} #{count}"
        else
          format("%s %3d%%", bar(percent), percent)
        end
      end

      def bar(percent)
        filled = BAR * percent / 100
        "#{"█" * filled}#{"░" * (BAR - filled)}"
      end

      # The rate over the whole run so far, and the time left at that rate. Steadier than a
      # rate over the last few ticks, which jumps about with every pause in the work
      def pace(node)
        seconds = @clock.call - node.started_at if node.started_at
        return nil unless seconds && seconds >= 1 && node.count.positive?
        rate = node.count / seconds
        per = (node.unit == "bytes") ? "#{TaskProgress.human_bytes(rate)}/s" : format((rate < 10) ? "%.1f/s" : "%d/s", rate)
        return per unless node.total && node.total > node.count
        "#{per}  ETA #{duration((node.total - node.count) / rate)}"
      end

      def elapsed(node)
        return nil unless node.started_at
        duration((node.finished_at || @clock.call) - node.started_at)
      end

      def duration(seconds)
        if seconds < 60 then format("%.1fs", seconds)
        elsif seconds < 3600 then format("%dm%02ds", seconds / 60, seconds % 60)
        else format("%dh%02dm", seconds / 3600, seconds % 3600 / 60)
        end
      end

      def columns = size[1]

      def rows = size[0]

      def size
        require "io/console"
        rows, cols = @io.winsize
        (rows.positive? && cols.positive?) ? [rows, cols] : DEFAULT_SIZE
      rescue NoMethodError, SystemCallError
        DEFAULT_SIZE
      end
    end
  end
end
