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
  #   TaskProgress::TurboSSE.response(task, renderer:, source: "progress-source")
  #
  # Once the task finishes it sends the last frame, removes the element with the id `source` -
  # the `<turbo-stream-source>`, so the browser does not reconnect to a finished stream - and ends.
  # Without a `source` the browser reconnects every `reconnect` seconds, and gets the last frame
  # each time. Given a key, it follows the tree handed off there, as SSE does
  class TurboSSE
    # What a Turbo SSE response is sent with - the same as an SSE one
    HEADERS = SSE::HEADERS #: Hash[String, String]

    # @rbs @task: TaskProgress
    # @rbs @renderer: TurboStreamOutput::_Renderer
    # @rbs @interval: Integer | Float
    # @rbs @heartbeat: Integer | Float
    # @rbs @source: String?
    # @rbs @reconnect: Integer | Float
    # @rbs @close: bool

    # A whole Rack response: status, headers and this body - or a 404, for a key with nothing at it
    #: (TaskProgress | String, **untyped) -> [Integer, Hash[String, String], TurboSSE | Array[String]]
    def self.response(source, **)
      [200, HEADERS.dup, new(source, **)]
    rescue KeyError
      [404, {"content-type" => "text/plain"}, ["Nothing to follow"]]
    end

    # Streams `task`, drawn by `renderer` - an HTMLRenderer, or anything that answers `id` and
    # `render(snapshot, from)`, `from` being the task's path. `source` is the id of the
    # `<turbo-stream-source>` to remove at the end
    #: (TaskProgress | String, renderer: TurboStreamOutput::_Renderer, ?stream: untyped, ?interval: Integer | Float, ?heartbeat: Integer | Float, ?reconnect: Integer | Float, ?source: String?) -> void
    def initialize(task, renderer:, stream: TaskProgress.stream, interval: 0.25, heartbeat: 15, reconnect: 2, source: nil)
      @close = task.is_a?(String)
      @task = task.is_a?(String) ? TaskProgress.follow(task, stream:) : task
      @reconnect = reconnect
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
      yield "retry: #{(@reconnect * 1000).round}\n\n"
      yield message(frame)
      until ended?
        next yield(": ping\n\n") unless queue.pop(timeout: @heartbeat)
        queue.clear # one frame for all of them: it draws the tree as it stands
        yield message(frame)
        sleep(@interval) unless ended?
      end
      yield message(frame)
      source = @source
      yield message(%(<turbo-stream action="remove" target="#{CGI.escapeHTML(source)}"></turbo-stream>)) if source
    ensure
      @task.remove_output(output) if output
      close
    end

    # Stops following a tree it followed by its key - Rack calls it when the response is over
    #: () -> void
    def close
      @task.log.close if @close
    end

    private

    # Finished, or pruned away - which is as finished as it will ever be
    #: () -> bool
    def ended?
      node = @task.log.snapshot[@task.path]
      node.nil? || node.finished?
    end

    #: () -> String
    def frame
      snapshot = @task.log.snapshot
      TurboStreamOutput.frame(@renderer.id, render(snapshot))
    end

    #: (State) -> String
    def render(snapshot) = @renderer.render(snapshot, @task.path)

    # An unnamed event - what `<turbo-stream-source>` listens for. A line of SSE ends at a CR as
    # much as at a LF, and task names and messages - curl's and ffmpeg's, say - are full of CRs
    #: (String) -> String
    def message(html) = "#{html.split(/\r\n|\r|\n/).map { "data: #{it}\n" }.join}\n"
  end
end
