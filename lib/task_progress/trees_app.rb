# frozen_string_literal: true
# rbs_inline: enabled

require "json"

class TaskProgress
  # A Rack app that serves handed-off trees to pages, by a Token rather than by the tree's key -
  # what TaskProgress.for_page hands out links to. The Railtie mounts it at `/task_progress/trees`.
  #
  #     GET  /:token/events          Server-Sent Events, see SSE
  #     GET  /:token/poll            the tree, polled or long-polled, see Poll
  #     POST /:token/cancellations   path=x3k0-00af (a form, or JSON)
  #       202  {"path": ..., "state": "requested"}   asked of whoever works on it
  #       200  {"path": ..., "state": "moot"}        nothing left to cancel - no such task, or it ended
  #       409  the task is not cancelable
  #     403  a token that is forged, mangled or expired
  #     404  a tree that is gone, or anything else
  #
  # Issuing the token is the authorization: it happens in an action of yours, which has decided
  # the page may see that tree. The key itself never leaves the server
  class TreesApp
    # @rbs @tokens: Token
    # @rbs @stream_store: untyped

    # Checks tokens with `tokens`, and reads trees from `stream_store` - TaskProgress.stream_store
    # unless given
    #: (tokens: Token, ?stream_store: untyped) -> void
    def initialize(tokens:, stream_store: nil)
      @tokens = tokens
      @stream_store = stream_store
    end

    # Serves one request
    #: (Hash[String, untyped]) -> [Integer, Hash[String, String], untyped]
    def call(env)
      _, token, action = env["PATH_INFO"].to_s.split("/", 3)
      key = @tokens.verify(token) or return respond(403, {error: "invalid or expired token"})
      stream_store = @stream_store || TaskProgress.stream_store
      case [env["REQUEST_METHOD"], action]
      in ["GET", "events"] then SSE.response(key, stream_store:)
      in ["GET", "poll"] then Poll.response(key, env, stream_store:)
      in ["POST", "cancellations"] then cancel(key, env, stream_store)
      else respond(404, {error: "not found"})
      end
    end

    private

    #: (String, Hash[String, untyped], untyped) -> [Integer, Hash[String, String], Array[String]]
    def cancel(key, env, stream_store)
      path = CancellationsApp.params(env)["path"].to_s.split("-")
      return respond(422, {error: "malformed path"}) unless path.length <= Wire::MAX_DEPTH && path.all? { it.match?(Wire::SEGMENT) }
      outcome = TaskProgress.fetch(key, stream_store:).request_cancel(path, "Canceled from the page")
      case outcome
      when :refused then respond(409, {error: "not cancelable"})
      when :moot then respond(200, {path: path.join("-"), state: "moot"})
      else respond(202, {path: path.join("-"), state: "requested"})
      end
    rescue KeyError
      respond(404, {error: "no such tree"})
    end

    #: (Integer, Hash[Symbol, untyped]) -> [Integer, Hash[String, String], Array[String]]
    def respond(status, body) = [status, {"content-type" => "application/json"}, [JSON.generate(body)]]
  end
end
