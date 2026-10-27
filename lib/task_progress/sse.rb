# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # A Rack response body streaming a tree as Server-Sent Events: first the tree so far, squashed
  # into one batch with `prev` 0, then every batch as it commits - each in a `batch` event whose
  # `id:` is its seq. A browser that reconnects starts over from a fresh squash, which is always
  # right and costs a few puts. The stream ends once the root is finished. Given a subtask, it
  # streams only that task's subtree, with the subtask as the root.
  #
  #     # Rack
  #     TaskProgress::SSE.response(task)
  #     # Rails
  #     headers.merge!(TaskProgress::SSE::HEADERS)
  #     self.response_body = TaskProgress::SSE.new(task)
  #
  # Given a key instead of a task - a tree handed off with TaskProgress.handoff - it follows that
  # tree from the stream for as long as it streams, and stops following when the stream ends or
  # the server closes it. `response` answers 404 for a key with nothing at it
  class SSE
    # What an SSE response is sent with
    HEADERS = {"content-type" => "text/event-stream", "cache-control" => "no-cache", "x-accel-buffering" => "no"}.freeze #: Hash[String, String]

    # @rbs @source: TaskProgress | Log
    # @rbs @heartbeat: Integer | Float
    # @rbs @reconnect: Integer | Float
    # @rbs @close: bool

    # A whole Rack response: status, headers and this body - or a 404, for a key with nothing at it
    #: (TaskProgress | Log | String, **untyped) -> [Integer, Hash[String, String], SSE | Array[String]]
    def self.response(source, **)
      [200, HEADERS.dup, new(source, **)]
    rescue KeyError
      [404, {"content-type" => "text/plain"}, ["Nothing to follow"]]
    end

    # One batch as an SSE event
    #: (Batch) -> String
    def self.frame(batch) = "id: #{batch.seq}\nevent: batch\ndata: #{Wire.dump(batch)}\n\n"

    # Streams the task - its subtree only, for a subtask - or the tree handed off at a key, from
    # `stream`. It pings every `heartbeat` seconds of quiet, and tells the browser to reconnect
    # after `reconnect` seconds
    #: (TaskProgress | Log | String, ?stream: untyped, ?heartbeat: Integer | Float, ?reconnect: Integer | Float) -> void
    def initialize(source, stream: TaskProgress.stream, heartbeat: 15, reconnect: 2)
      @close = source.is_a?(String)
      @source = source.is_a?(String) ? TaskProgress.follow(source, stream:) : source
      @heartbeat = heartbeat
      @reconnect = reconnect
    end

    # Stops following a tree it followed by its key - Rack calls it when the response is over
    #: () -> void
    def close
      log.close if @close
    end

    # Yields the stream a chunk at a time, until the task finishes - as a Rack body does
    #: () { (String) -> void } -> void
    def each
      queue = Thread::Queue.new
      behind = false
      # A client that stops reading would have every batch pile up here. Past BACKLOG it gets
      # one squash of the tree instead, as of when it reads on
      output = @source.add_output(replay: true) do |batch, _log|
        next queue << batch if queue.size < BACKLOG
        behind = true
        queue.clear
      end
      yield "retry: #{(@reconnect * 1000).round}\n\n"
      # A task pruned away before anyone asked: a tree with nothing in it, and the end
      return yield(SSE.frame(Batch.new(log: log.id, prev: 0, seq: [log.seq, 1].max, at: 0.0, events: []))) unless present?
      loop do
        batch = queue.pop(timeout: @heartbeat)
        if behind
          behind = false
          batch = log.squashed(path)
        end
        next yield(": ping\n\n") if batch.nil?
        yield SSE.frame(batch)
        break if finishes_root?(batch)
      end
    ensure
      @source.remove_output(output) if output
      close
    end

    # How many batches wait for a slow client before it gets a squash instead
    BACKLOG = 1000 #: Integer

    private

    #: () -> Log
    def log = (source = @source).is_a?(Log) ? source : source.log

    #: () -> path
    def path = (source = @source).is_a?(Log) ? [] : source.path

    #: () -> bool
    def present? = log.snapshot.key?(path)

    # Judged by what was sent, never by the snapshot: that runs ahead of delivery, and ending on
    # it could cut the stream before the batch that finished the root went out. An empty reset
    # is a branch whose task was pruned, which will not come back either
    #: (Batch) -> bool
    def finishes_root?(batch)
      return true if batch.reset? && batch.events.empty?
      batch.events.any? do |event|
        event.path.empty? && (%i[done fail cancel].include?(event.op) ||
          (event.op == :put && %i[done failed canceled].include?(event.value[:status])))
      end
    end
  end
end
