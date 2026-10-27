# frozen_string_literal: true
# rbs_inline: enabled

require "digest"
require "uri"

class TaskProgress
  # The tree over plain GETs, for where Server-Sent Events do not get through - a proxy that
  # buffers, a host that cuts long responses, a client that is not a browser. Every answer is
  # the whole tree, squashed into one batch with `prev` 0, and its ETag says which tree that is:
  # a client that sends it back in `If-None-Match` gets a 304 until something changes.
  #
  # Asked with `?wait=N`, it holds the request up to N seconds (`max_wait` at most) for a change
  # before saying 304 - long polling, which holds a server thread for that long, but answers
  # the moment there is news. `followPollingAt` in `task_tree.js` does all of this.
  #
  #     # Rack
  #     TaskProgress::Poll.response(task, env)
  #     # Rails
  #     status, headers, body = TaskProgress::Poll.response(task, request.env)
  #     render json: body.first, status:, headers:
  #
  # For a tree another process writes, poll `TaskProgress.fetch(key)`; to long-poll one, give it
  # `TaskProgress.follow(key)` and `close: true`, which stops following once it has answered
  module Poll
    # What a poll is answered with
    HEADERS = {"content-type" => "application/json", "cache-control" => "no-cache"}.freeze #: Hash[String, String]

    # A whole Rack response for the task's tree - its subtree, for a subtask
    #: (TaskProgress, ?Hash[String, untyped], ?max_wait: Integer | Float, ?close: bool) -> [Integer, Hash[String, String], Array[String]]
    def self.response(task, env = {}, max_wait: 25, close: false)
      seen = env["HTTP_IF_NONE_MATCH"]
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait(env, max_wait)
      loop do
        seq = task.log.seq
        batch = task.log.squashed(task.path)
        tag = etag(batch)
        return [200, HEADERS.merge("etag" => tag), [Wire.dump(batch)]] unless tag == seen
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return [304, HEADERS.merge("etag" => tag), []] if left <= 0 || task.finished?
        task.log.wait_for_change(seq, left)
      end
    ensure
      task.log.close if close
    end

    # Which tree a squash is: the same tree, however many batches it took, gets the same tag. Times
    # are left out - a tree read from a stream has them moved onto this clock, a little differently
    # every read, and they never change without something else changing with them
    #: (Batch) -> String
    def self.etag(batch)
      ops = batch.events.map { [it.path, it.op, (it.op == :put) ? it.value.except(*TIMES) : it.value] }
      %("#{Digest::SHA256.hexdigest(JSON.generate(ops))[0, 24]}")
    end

    TIMES = %i[opened_at started_at finished_at].freeze #: Array[Symbol]
    private_constant :TIMES

    # The seconds asked for in `?wait=`, up to `max_wait`
    #: (Hash[String, untyped], Integer | Float) -> Float
    def self.wait(env, max_wait)
      asked = URI.decode_www_form(env["QUERY_STRING"].to_s).to_h["wait"]
      Float(asked.to_s, exception: false).to_f.clamp(0.0, max_wait.to_f)
    rescue ArgumentError
      0.0
    end
    private_class_method :wait
  end
end
