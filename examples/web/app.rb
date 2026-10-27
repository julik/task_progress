# frozen_string_literal: true

require "erb"
require "json"
require "rack"
require "assiette"
require_relative "../scenarios"

# The bench behind bin/dev. Starts scenario jobs in this process and serves each tree as SSE.
#
#   GET  /                       the bench page; its scripts and styles come from Assiette, with
#                                the gem's own JS mounted at /task_progress
#   GET  /scenarios              what can be started
#   GET  /jobs                   the jobs started lately, newest first
#   POST /jobs?scenario=&speed=  starts one
#   POST /jobs/:id/cancel        raises Interrupt in its thread
#   GET  /jobs/:id/events        its tree as SSE; with ?drop_after=N the stream is cut after N
#                                frames, so the browser has to reconnect and resume
class BenchApp
  PUBLIC = File.expand_path("public", __dir__)
  PAGE = ERB.new(File.read(File.join(PUBLIC, "index.html.erb")), trim_mode: "<>")
  KEEP = 30

  # `number` counts jobs as they start - the order to list and evict them in, wall clock or not
  Job = Data.define(:id, :number, :scenario, :root, :thread)

  def initialize
    @jobs = {}
    @started = 0
    @lock = Mutex.new
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
        Job.new(id: root.log.id, number: @started += 1, scenario: scenario.id, root:, thread:).tap do |job|
          @jobs[job.id] = job
          @jobs.delete(@jobs.values.min_by(&:number).id) while @jobs.size > KEEP
        end
      end
      json(describe(job), 201)
    in ["POST", %r{\A/jobs/(\w+)/cancel\z}]
      job = find($1) or return json({error: "no such job"}, 404)
      job.thread.raise(Interrupt, "Cancelled from the bench") if job.thread.alive?
      json(describe(job))
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
    {id: job.id, scenario: job.scenario, events: "/jobs/#{job.id}/events", status: root.status,
     percent: root.percent, number: job.number}
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
