# frozen_string_literal: true

class TaskProgress
  module Outputs
    # Redraws the tree in place on a terminal, from a ticker thread of its own so spinners turn
    # while nothing reports. A finished subtree folds into its one line, and when the tree is
    # taller than the screen the finished lines go first, then the ones not started. When the
    # root finishes the tree is drawn one last time and left on screen - or erased, with `erase: true`
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
        @lock.synchronize do
          @log = log
          return if @closed
          if log.snapshot[[]]&.finished?
            finish
          elsif @interval.nil?
            draw
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
          nil
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

      def elapsed(node)
        return nil unless node.started_at
        seconds = (node.finished_at || @clock.call) - node.started_at
        (seconds < 60) ? format("%.1fs", seconds) : format("%dm%02ds", seconds / 60, seconds % 60)
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
