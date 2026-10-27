# frozen_string_literal: true
# rbs_inline: enabled

require "cgi/escape"

class TaskProgress
  # A Rack body streaming a tree as Turbo Streams over Server-Sent Events, for a page that shows
  # it with `<turbo-stream-source src="...">` - Turbo with no Action Cable, and no JavaScript of
  # your own. Every frame replaces the whole tree by morphing, at most every `interval` seconds
  # however fast the tree changes; a reconnect starts with the whole tree, so nothing is ever
  # missed for good. Given a subtask, it streams that branch alone.
  #
  #   [200, TaskProgress::TurboSSE::HEADERS, TaskProgress::TurboSSE.new(task, renderer:)]
  #
  # Once the task finishes it sends the last frame, removes the element with the id `source` -
  # the `<turbo-stream-source>`, so the browser does not reconnect to a finished stream - and ends
  class TurboSSE
    # What a Turbo SSE response is sent with - the same as an SSE one
    HEADERS = SSE::HEADERS #: Hash[String, String]

    # @rbs @task: TaskProgress
    # @rbs @renderer: TurboStreamOutput::_Renderer
    # @rbs @interval: Integer | Float
    # @rbs @heartbeat: Integer | Float
    # @rbs @source: String?

    # Streams `task`, drawn by `renderer` - an HTMLRenderer, or anything that answers `id` and
    # `render(snapshot, from)`, `from` being the task's path. `source` is the id of the
    # `<turbo-stream-source>` to remove at the end
    #: (TaskProgress, renderer: TurboStreamOutput::_Renderer, ?interval: Integer | Float, ?heartbeat: Integer | Float, ?source: String?) -> void
    def initialize(task, renderer:, interval: 0.25, heartbeat: 15, source: nil)
      @task = task
      @renderer = renderer
      @interval = interval
      @heartbeat = heartbeat
      @source = source
    end

    # Yields the stream a chunk at a time, until the task finishes - as a Rack body does
    #: () { (String) -> void } -> void
    def each
      queue = Thread::Queue.new
      output = @task.add_output(replay: false) { |batch, _log| queue << batch }
      yield "retry: 2000\n\n"
      yield message(frame)
      until @task.finished?
        next yield(": ping\n\n") unless queue.pop(timeout: @heartbeat)
        queue.clear # one frame for all of them: it draws the tree as it stands
        yield message(frame)
        sleep(@interval) unless @task.finished?
      end
      yield message(frame)
      source = @source
      yield message(%(<turbo-stream action="remove" target="#{CGI.escapeHTML(source)}"></turbo-stream>)) if source
    ensure
      @task.remove_output(output) if output
    end

    private

    #: () -> String
    def frame
      snapshot = @task.log.snapshot
      TurboStreamOutput.frame(@renderer.id, render(snapshot))
    end

    #: (State) -> String
    def render(snapshot) = @renderer.render(snapshot, @task.path)

    # An unnamed event - what `<turbo-stream-source>` listens for
    #: (String) -> String
    def message(html) = "#{html.lines.map { "data: #{it.chomp}\n" }.join}\n"
  end
end
