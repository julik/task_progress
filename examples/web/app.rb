# frozen_string_literal: true

require "erb"
require "json"
require "rack"
require "securerandom"
require "assiette"
require_relative "../scenarios"

# The bench behind bin/dev. Starts scenario jobs in this process and serves each tree as SSE.
#
#   GET  /                       the bench page; its scripts and styles come from Assiette, with
#                                the gem's own JS mounted at /task_progress
#   GET  /scenarios              what can be started
#   GET  /jobs                   the jobs started lately, newest first
#   POST /jobs?scenario=&speed=  starts one
#   POST /jobs/:id/cancel        raises Interrupt in its thread - the bench's own "Cancel job"
#   POST /jobs/:id/cancellations creates the cancellation of one task: JSON {path, token}, `path`
#                                its ids joined with a dash and `token` the job's cancel_token. Asking
#                                again for the same task gives back the same cancellation
#   GET  /jobs/:id/cancellations/:id   one cancellation, and how it went
#   GET  /jobs/:id/turbo         its tree as Turbo Streams over SSE, for <turbo-stream-source>
#   GET  /jobs/:id/events        its tree as SSE; with ?drop_after=N the stream is cut after N
#                                frames, so the browser has to reconnect and resume
#   PUT  /uploads/:name          takes a file and throws it away, a little later; one named
#                                too-big.* gets a 413, for a failed upload to look at
class BenchApp
  PUBLIC = File.expand_path("public", __dir__)
  PAGE = ERB.new(File.read(File.join(PUBLIC, "index.html.erb")), trim_mode: "<>")
  KEEP = 30

  # `number` counts jobs as they start - the order to list and evict them in, wall clock or not
  Job = Data.define(:id, :number, :scenario, :root, :thread, :cancellations)

  # A request to cancel one task. `state` is where it got to: "canceled", "requested" while a
  # child process has been asked and has not answered down the stream yet, or "moot" - the task
  # had already ended, or the process it ran in had gone, by the time the request arrived
  Cancellation = Struct.new(:id, :path, :state, :requested_at) do
    def to_h = {id:, path: path.join("-"), state:, requested_at:}
  end
  STATES = {canceled: "canceled", forwarded: "requested", moot: "moot"}.freeze

  def initialize
    @jobs = {}
    @started = 0
    @lock = Mutex.new
    @tokens = TaskProgress::Token.new(SecureRandom.hex(32))
    @assets = Assiette::AssetHandler.new(root: PUBLIC, additional_directory_mappings: {"/task_progress" => TaskProgress.js_path})
    @app = Assiette::Server.new(method(:route), @assets)
  end

  def call(env) = @app.call(env)

  def jobs = @lock.synchronize { @jobs.values }

  private

  def route(env)
    request = Rack::Request.new(env)
    case [request.request_method, request.path_info]
    in ["GET", "/" | "/index.html"]
      # The page links every asset by its content hash, so it must never be cached itself
      [200, {"content-type" => "text/html; charset=utf-8", "cache-control" => "no-store"}, [PAGE.result(binding)]]
    in ["GET", "/scenarios"]
      json(Scenarios::ALL.map { {id: it.id, title: it.title, description: it.description} })
    in ["GET", "/jobs"]
      json(jobs.sort_by(&:number).reverse.map { describe(it) })
    in ["POST", "/jobs"]
      scenario = Scenarios.find(request.params["scenario"].to_s) or return json({error: "no such scenario"}, 404)
      speed = Float(request.params.fetch("speed", "1"), exception: false)&.clamp(0.1, 100) || 1.0
      root, thread = scenario.start.call(speed:)
      job = @lock.synchronize do
        Job.new(id: root.log.id, number: @started += 1, scenario: scenario.id, root:, thread:, cancellations: {}).tap do |job|
          @jobs[job.id] = job
          @jobs.delete(@jobs.values.min_by(&:number).id) while @jobs.size > KEEP
        end
      end
      json(describe(job), 201)
    in ["PUT", %r{\A/uploads/([^/]+)\z}]
      IO.copy_stream(request.body, File::NULL)
      # An answer that takes a moment, so the page shows every byte sent and the upload not yet through
      sleep 1
      $1.start_with?("too-big") ? json({error: "too big"}, 413) : [204, {}, []]
    in ["POST", %r{\A/jobs/(\w+)/cancel\z}]
      job = find($1) or return json({error: "no such job"}, 404)
      job.thread.raise(Interrupt, "Cancelled from the bench") if job.thread.alive?
      json(describe(job))
    in ["POST", %r{\A/jobs/(\w+)/cancellations\z}]
      answer = cancel(request, $1)
      # A Turbo form gets an empty Turbo Stream back, whatever became of it: the next frame shows it
      if request.get_header("HTTP_ACCEPT").to_s.include?("turbo-stream")
        [answer.first.clamp(200, 299), {"content-type" => "text/vnd.turbo-stream.html"}, [""]]
      else
        answer
      end
    in ["GET", %r{\A/jobs/(\w+)/cancellations/([\w-]+)\z}]
      job = find($1)
      cancellation = job&.cancellations&.[]($2) or return json({error: "no such cancellation"}, 404)
      json(settle(job, cancellation).to_h)
    in ["GET", %r{\A/jobs/(\w+)/turbo\z}]
      job = find($1) or return [404, {}, ["no such job"]]
      renderer = TaskProgress::HTMLRenderer.new(id: "turbo-tree", cancel_url: "/jobs/#{job.id}/cancellations", cancel_token: @tokens.issue(job.id))
      [200, TaskProgress::TurboSSE::HEADERS.dup, TaskProgress::TurboSSE.new(job.root, renderer:, source: "turbo-source")]
    in ["GET", %r{\A/jobs/(\w+)/poll\z}]
      job = find($1) or return [404, {}, ["no such job"]]
      TaskProgress::Poll.response(job.root, env, max_wait: 10)
    in ["GET", %r{\A/jobs/(\w+)/events\z}]
      job = find($1) or return [404, {}, ["no such job"]]
      drop_after = Integer(request.params["drop_after"], exception: false)
      body = TaskProgress::SSE.new(job.root)
      body = Cut.new(body, drop_after) if drop_after&.positive?
      [200, TaskProgress::SSE::HEADERS.dup, body]
    else
      [404, {"content-type" => "text/plain"}, ["not found"]]
    end
  end

  def find(id) = @lock.synchronize { @jobs[id] }

  def asset_path(path) = @assets.absolute_asset_url_path(path)

  def asset_integrity(path) = @assets.asset_integrity(path)

  def describe(job)
    root = job.root
    {id: job.id, scenario: job.scenario, events: "/jobs/#{job.id}/events", poll: "/jobs/#{job.id}/poll", status: root.status,
     percent: root.percent, number: job.number,
     cancellations: "/jobs/#{job.id}/cancellations", cancel_token: @tokens.issue(job.id, expires_in: 3600)}
  end

  # The token is checked before anything else, and it names the job, so it holds even for a job
  # that is gone. What can be canceled is the tree's to say, never the browser's: the request only
  # names a task, and the tree decides - in one transaction, so a task finishing as the request
  # arrives makes it moot rather than an error
  def cancel(request, job_id)
    params = (request.media_type == "application/json") ? begin
      JSON.parse(request.body.read)
    rescue
      {}
    end : request.params
    return json({error: "invalid or expired token"}, 403) unless params.is_a?(Hash) && @tokens.verify(params["token"]) == job_id
    path = params["path"].to_s.split("-")
    return json({error: "malformed path"}, 422) unless path.length <= TaskProgress::Wire::MAX_DEPTH && path.all? { it.match?(TaskProgress::Wire::SEGMENT) }

    id = path.empty? ? "root" : path.join("-")
    job = find(job_id) or return json(Cancellation.new(id, path, "moot", Time.now.to_f).to_h, 201)
    @lock.synchronize do
      if (existing = job.cancellations[id])
        return [200, {"content-type" => "application/json", "location" => "/jobs/#{job_id}/cancellations/#{id}"}, [JSON.generate(settle(job, existing).to_h)]]
      end
      outcome = job.root.request_cancel(path, "Canceled from the browser")
      return json({error: "not cancelable"}, 409) if outcome == :refused
      cancellation = job.cancellations[id] = Cancellation.new(id, path, STATES.fetch(outcome), Time.now.to_f)
      # A child answers down the stream, if it answers: the cancel arriving in the tree settles it
      job.root.find(path)&.on_cancel { cancellation.state = "canceled" } if outcome == :forwarded
      [201, {"content-type" => "application/json", "location" => "/jobs/#{job_id}/cancellations/#{id}"}, [JSON.generate(cancellation.to_h)]]
    end
  end

  # A child that was asked may have finished the task before the request reached it
  def settle(job, cancellation)
    task = job.root.find(cancellation.path)
    cancellation.state = "moot" if cancellation.state == "requested" && (task.nil? || (task.finished? && !task.canceled?))
    cancellation
  end

  def json(data, status = 200) = [status, {"content-type" => "application/json"}, [JSON.generate(data)]]

  # Ends the stream after `frames` batches, the way a proxy or a deploy would
  class Cut
    def initialize(body, frames)
      @body = body
      @frames = frames
    end

    def each
      sent = 0
      @body.each do |chunk|
        yield chunk
        sent += 1 if chunk.start_with?("id:")
        break if sent >= @frames
      end
    end
  end
end
