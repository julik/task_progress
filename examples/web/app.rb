# frozen_string_literal: true

require "json"
require "rack"
require "rack/static"
require_relative "../scenarios"

# The bench behind bin/dev. Starts scenario jobs in this process and serves each tree as SSE.
#
#   GET  /                       the bench page
#   GET  /scenarios              what can be started
#   GET  /jobs                   the jobs started lately, newest first
#   POST /jobs?scenario=&speed=  starts one
#   POST /jobs/:id/cancel        raises Interrupt in its thread
#   GET  /jobs/:id/events        its tree as SSE; with ?drop_after=N the stream is cut after N
#                                frames, so the browser has to reconnect and resume
class BenchApp
  PUBLIC = File.expand_path("public", __dir__)
  KEEP = 30
  ASSETS = %w[/index.html /bench.js /bench.css /style.css /task_tree.js /row_view.js /stimulus_controller.js /react_task_tree.js]

  # `number` counts jobs as they start - the order to list and evict them in, wall clock or not
  Job = Data.define(:id, :number, :scenario, :root, :thread)

  def initialize
    @jobs = {}
    @started = 0
    @lock = Mutex.new
    @static = Rack::Static.new(method(:route), urls: ASSETS, root: PUBLIC, header_rules: [[:all, {"cache-control" => "no-store"}]])
  end

  def call(env) = @static.call(env)

  def jobs = @lock.synchronize { @jobs.values }

  private

  def route(env)
    request = Rack::Request.new(env)
    case [request.request_method, request.path_info]
    in ["GET", "/"] then [302, {"location" => "/index.html"}, []]
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
