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
  #     [200, TaskProgress::SSE::HEADERS, TaskProgress::SSE.new(task)]
  #     # Rails
  #     headers.merge!(TaskProgress::SSE::HEADERS)
  #     self.response_body = TaskProgress::SSE.new(task)
  #
  # The tree must live in the serving process. For one that lives in a job elsewhere, have the
  # job publish to a stream (PublishingOutput) and serve that
  class SSE
    # What an SSE response is sent with
    HEADERS = {"content-type" => "text/event-stream", "cache-control" => "no-cache", "x-accel-buffering" => "no"}.freeze #: Hash[String, String]

    # @rbs @source: TaskProgress | Log
    # @rbs @heartbeat: Integer | Float
    # @rbs @retry_ms: Integer

    # A whole Rack response: status, headers and this body
    #: (TaskProgress | Log, **untyped) -> [Integer, Hash[String, String], SSE]
    def self.response(task, **) = [200, HEADERS.dup, new(task, **)]

    # One batch as an SSE event
    #: (Batch) -> String
    def self.frame(batch) = "id: #{batch.seq}\nevent: batch\ndata: #{Wire.dump(batch)}\n\n"

    # Streams the task - its subtree only, for a subtask - pinging every `heartbeat` seconds of quiet, and telling the browser to reconnect after `retry_ms`
    #: (TaskProgress | Log, ?heartbeat: Integer | Float, ?retry_ms: Integer) -> void
    def initialize(task_or_log, heartbeat: 15, retry_ms: 2000)
      @source = task_or_log
      @heartbeat = heartbeat
      @retry_ms = retry_ms
    end

    # Yields the stream a chunk at a time, until the task finishes - as a Rack body does
    #: () { (String) -> void } -> void
    def each
      queue = Thread::Queue.new
      output = @source.add_output(replay: true) { |batch, _log| queue << batch }
      yield "retry: #{@retry_ms}\n\n"
      loop do
        batch = queue.pop(timeout: @heartbeat)
        next yield(": ping\n\n") if batch.nil?
        yield SSE.frame(batch)
        break if finishes_root?(batch)
      end
    ensure
      @source.remove_output(output) if output
    end

    private

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
