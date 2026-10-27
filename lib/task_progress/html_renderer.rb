# frozen_string_literal: true
# rbs_inline: enabled

require "cgi/escape"

class TaskProgress
  # Draws a tree as HTML - the same rows, with the same classes, as the browser client's renderers
  # draw, so `task_tree.css` styles both and a page can move from one to the other unchanged.
  # This is what TurboStreamOutput sends, and what TurboSSE streams.
  #
  # Elapsed times are `<task-progress-clock>` elements (`task_progress_clock.js`), which tick on
  # between frames; everything else is as it was when the tree was drawn. A cancelable task gets
  # a cancel button that is a plain form, posting the task's path and `cancel_token` to
  # `cancel_url` - so it needs no JavaScript, and Turbo submits it without leaving the page.
  #
  # To draw rows your own way, subclass it and override `row`, or hand TurboStreamOutput anything
  # that answers `id` and `render(snapshot, from = [])` - say, an object that renders a partial
  class HTMLRenderer
    # A circle with a cross in it, drawn in the row's text color - the same in every font
    CANCEL_ICON = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M5.6 5.6l4.8 4.8M10.4 5.6l-4.8 4.8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>' #: String

    GLYPHS = {done: "✓", failed: "✗", canceled: "⊘", pending: "·"}.freeze #: Hash[Symbol, String]
    private_constant :GLYPHS

    # The id of the element the tree is drawn in - what a Turbo Stream targets
    attr_reader :id #: String

    # @rbs @cancel_url: String?
    # @rbs @cancel_token: String?
    # @rbs @clock: ^() -> Float

    # Draws into an element with the id `id`. Without a `cancel_url`, no task offers a cancel
    # button. `clock` is for tests to pin down
    #: (id: String, ?cancel_url: String?, ?cancel_token: String?, ?clock: ^() -> Float) -> void
    def initialize(id:, cancel_url: nil, cancel_token: nil, clock: -> { Process.clock_gettime(Process::CLOCK_REALTIME) })
      @id = id
      @cancel_url = cancel_url
      @cancel_token = cancel_token
      @clock = clock
    end

    # The whole tree in its element - or the subtree at `from`, drawn as a tree of its own
    #: (State, ?path) -> String
    def render(snapshot, from = [])
      rows = snapshot.rows(from).map do |path, node|
        depth = path.length - from.length
        node.is_a?(Fold) ? fold(path, node, depth:) : row(snapshot, path, node, depth:)
      end
      %(<div id="#{h(@id)}" class="tree" data-task-progress-at="#{@clock.call}">#{rows.join}</div>)
    end

    # One task's row, `depth` levels in
    #: (State, path, Node, ?depth: Integer) -> String
    def row(snapshot, path, node, depth: path.length)
      status = (node.status == :done && !snapshot.complete?(path)) ? :active : node.status
      glyph = GLYPHS[status]
      icon = glyph ? "<span>#{glyph}</span>" : '<span class="spin"></span>'
      indeterminate = !!(node.children.empty? && node.indeterminate && node.status == :active)
      percent = snapshot.percent(path)
      classes = ["row", status, ("stale" if node.stale)].compact.join(" ")
      <<~HTML.delete("\n")
        <div class="#{classes}" id="#{h(@id)}-#{h(path.empty? ? "root" : path.join("-"))}" data-path="#{h(path.join("-"))}">
        <div class="label" style="padding-left: #{depth * 18}px">
        <span class="icon">#{icon}</span><span class="name">#{h(node.name)}</span><span class="message">#{h(message(node))}</span>
        </div>
        <div class="bar#{" indeterminate" if indeterminate}"><span style="width: #{percent}%"></span></div>
        #{cancel(path, node)}
        <div class="measure">#{measure(path, node, percent, indeterminate)}</div>
        </div>
      HTML
    end

    # Siblings folded into one row, see State#rows - drawn as a row like any other, so the
    # columns line up
    #: (path, Fold, ?depth: Integer) -> String
    def fold(path, fold, depth: path.length)
      done = fold.status == :done
      <<~HTML.delete("\n")
        <div class="row folded #{done ? "done" : "pending"}" id="#{h(@id)}-#{h(path.join("-"))}" data-path="#{h(path.join("-"))}">
        <div class="label" style="padding-left: #{depth * 18}px">
        <span class="icon"><span>#{GLYPHS[done ? :done : :pending]}</span></span><span class="name">#{h(fold.name)}</span><span class="message"></span>
        </div>
        <div class="bar"><span style="width: #{done ? 100 : 0}%"></span></div>
        <span class="cancel-slot"></span>
        <div class="measure"></div>
        </div>
      HTML
    end

    private

    #: (String?) -> String
    def h(text) = CGI.escapeHTML(text.to_s)

    #: (Node) -> String
    def message(node)
      said = (node.status == :failed) ? node.error&.dig(:message) : [pace(node), node.message].compact.reject(&:empty?).join(" · ")
      [("attempt #{node.attempt}" if node.attempt.to_i > 1), said].compact.reject(&:empty?).join(" · ")
    end

    # The rate over the run so far, and the time left at it
    #: (Node) -> String?
    def pace(node)
      started = node.started_at
      return nil unless node.status == :active && node.children.empty? && started && node.count.positive?
      seconds = @clock.call - started
      return nil if seconds < 1
      rate = node.count / seconds
      per = if node.unit == "bytes"
        "#{TaskProgress.human_bytes(rate)}/s"
      else
        ((rate < 10) ? format("%.1f/s", rate) : "#{rate.floor}/s")
      end
      total = node.total
      return per unless total && total > node.count
      "#{per}, #{TaskProgress.duration((total - node.count) / rate)} left"
    end

    #: (path, Node, Integer, bool) -> String
    def measure(path, node, percent, indeterminate)
      total = node.total
      if node.children.empty? && total
        (node.unit == "bytes") ? "#{TaskProgress.human_bytes(node.count)} / #{TaskProgress.human_bytes(total)}" : "#{node.count} / #{total}"
      elsif indeterminate
        clock(node)
      else
        "#{percent}%"
      end
    end

    # Ticks on in the browser between frames, from the time the tree was drawn
    #: (Node) -> String
    def clock(node)
      started = node.started_at or return ""
      seconds = [(node.finished_at || @clock.call) - started, 0].max
      ended = %( finished="#{node.finished_at}") if node.finished_at
      %(<task-progress-clock started="#{started}" drawn="#{@clock.call}"#{ended}>#{format("%.1fs", seconds)}</task-progress-clock>)
    end

    # The cancel column is there on every row, so the bars line up
    #: (path, Node) -> String
    def cancel(path, node)
      return '<span class="cancel-slot"></span>' unless @cancel_url && node.cancelable && !node.finished?
      <<~HTML.delete("\n")
        <form class="cancel-slot" action="#{h(@cancel_url)}" method="post" data-turbo="true">
        <input type="hidden" name="path" value="#{h(path.join("-"))}">
        <input type="hidden" name="token" value="#{h(@cancel_token)}">
        <button type="submit" class="cancel" aria-label="Cancel #{h(node.name)}">#{CANCEL_ICON}</button>
        </form>
      HTML
    end
  end
end
