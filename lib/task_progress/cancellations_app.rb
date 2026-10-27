# frozen_string_literal: true
# rbs_inline: enabled

require "json"
require "uri"

class TaskProgress
  # A Rack app that takes the cancel buttons HTMLRenderer draws, for a tree that lives in another
  # process - a job broadcasting with TaskProgress.broadcast. It cannot cancel anything itself:
  # it checks the request's token, and leaves the request in the store the job watches. The job
  # decides, as it does for any request (see TaskProgress#request_cancel), and the cancel comes
  # back in its next frame.
  #
  # A Turbo form submission is answered with an empty Turbo Stream, which changes nothing on the
  # page - the frame that follows does. Anything else gets 202 and a little JSON
  class CancellationsApp
    # @rbs @store: TurboStreamOutput::_Store
    # @rbs @tokens: CancelToken

    # Leaves requests in `store`, for tokens `tokens` issued
    #: (store: TurboStreamOutput::_Store, tokens: CancelToken) -> void
    def initialize(store:, tokens:)
      @store = store
      @tokens = tokens
    end

    # Takes a POST with `path` - the task's ids joined with a dash - and `token`, as a form or JSON
    #: (Hash[String, untyped]) -> [Integer, Hash[String, String], Array[String]]
    def call(env)
      return respond(405, {error: "POST a cancellation"}) unless env["REQUEST_METHOD"] == "POST"
      params = params(env)
      key = @tokens.verify(params["token"]&.to_s) or return respond(403, {error: "invalid or expired token"})
      path = params["path"].to_s.split("-")
      return respond(422, {error: "malformed path"}) unless path.length <= Wire::MAX_DEPTH && path.all? { it.match?(Wire::SEGMENT) }
      @store.write(CancellationsApp.request_key(key, path), "Canceled from the browser")
      return [200, {"content-type" => "text/vnd.turbo-stream.html"}, [""]] if env["HTTP_ACCEPT"].to_s.include?("turbo-stream")
      respond(202, {path: path.join("-"), state: "requested"})
    end

    # Where a request to cancel the task at `path` waits, for the tree stored under `key`
    #: (String, path) -> String
    def self.request_key(key, path) = "#{key}/cancel/#{path.join("-")}"

    private

    #: (Hash[String, untyped]) -> Hash[String, untyped]
    def params(env)
      # Mounted in Rails, a middleware (Rack::MethodOverride, looking for `_method`) has read a
      # form's body already - and left it parsed here
      form = env["rack.request.form_hash"]
      return form if form.is_a?(Hash)
      input = env["rack.input"]
      input.rewind if input.respond_to?(:rewind)
      body = input&.read(4096).to_s
      if env["CONTENT_TYPE"].to_s.include?("json")
        parsed = begin
          JSON.parse(body)
        rescue
          nil
        end
        parsed.is_a?(Hash) ? parsed : {}
      else
        URI.decode_www_form(body).to_h
      end
    rescue ArgumentError
      {}
    end

    #: (Integer, Hash[Symbol, untyped]) -> [Integer, Hash[String, String], Array[String]]
    def respond(status, body) = [status, {"content-type" => "application/json"}, [JSON.generate(body)]]
  end
end
