# A Rails app of the smallest kind, with TaskProgress in it - run in a process of its own by
# test/rails_test.rb, so that Rails never leaks into the tests that prove the gem needs none
require "bundler/setup"
require "logger"
require "rails"
require "action_controller/railtie"
require "active_job/railtie"
require "action_cable/engine"
require "active_model"
require "turbo-rails"
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "task_progress"
require "rack/mock"
require "minitest/autorun"

class CheckApp < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.secret_key_base = "s" * 64
  config.cache_store = :memory_store
  config.logger = Logger.new(nil)
  config.hosts.clear
  config.action_controller.allow_forgery_protection = false
end
CheckApp.initialize!
ActionCable.server.config.cable = {"adapter" => "test"}
ActionCable.server.config.logger = Logger.new(nil)

class Import
  include ActiveModel::Model
  include ActiveModel::Conversion

  attr_accessor :id
  def persisted? = true
  def to_param = id.to_s
end

class HaltingJob < ActiveJob::Base
  before_perform { throw :abort }
  def perform(import) = import.note("never")
end

class ImportJob < ActiveJob::Base
  retry_on RuntimeError, wait: 0, attempts: 2
  cattr_accessor :failing, :seen

  def perform(rows, import)
    self.class.seen = import
    import.subtask("Rows", total: rows) do |t|
      rows.times { t.tick }
      raise "flaky" if self.class.failing && executions == 1
    end
  end
end

# What RECIPES.md shows, as it shows it
class UploadsController < ActionController::Base
  KEYS = {}

  def create
    import = TaskProgress.handoff("Importing", cancelable: true)
    KEYS[params[:id]] = import.key
    ImportJob.perform_later(3, import)
    head :accepted
  end

  def progress
    status, headers, body = TaskProgress::Poll.response(TaskProgress.fetch(KEYS.fetch(params[:id])), request.env)
    response.headers.merge!(headers)
    self.status = status
    self.response_body = body
  end

  def cancel
    TaskProgress.fetch(KEYS.fetch(params[:id])).request_cancel(params[:path].to_s, "Canceled from the page")
    head :accepted
  end
end

class ReportsController < ActionController::Base
  include ActionController::Live

  def build
    response.headers.merge!(TaskProgress::SSE::HEADERS)
    root = TaskProgress.new("Building the report", cancelable: true)
    work = Thread.new do
      Rails.application.executor.wrap do
        root.run { |r| r.subtask("Rows", total: 3) { |rows| 3.times { rows.tick && sleep(0.01) } } }
      end
    end
    TaskProgress::SSE.new(root).each { response.stream.write(it) }
  rescue ActionController::Live::ClientDisconnected
    root.cancel!("Nobody is watching any more")
  ensure
    work&.join
    response.stream.close
  end
end

CheckApp.routes.append do
  post "/uploads/:id" => "uploads#create"
  get "/uploads/:id/progress" => "uploads#progress"
  post "/uploads/:id/cancel" => "uploads#cancel"
  get "/reports/build" => "reports#build"
end
CheckApp.reload_routes!

class RailsAppCheck < Minitest::Test
  # The test adapter keeps what is enqueued - a retry included - and this runs it all, through
  # the queue's own serialization, until nothing is left
  def perform_enqueued_jobs
    adapter = ActiveJob::Base.queue_adapter = ActiveJob::QueueAdapters::TestAdapter.new
    yield
    while (job = adapter.enqueued_jobs.shift)
      ActiveJob::Base.execute(job.select { |k, _| k.is_a?(String) })
    end
  end

  def setup = Rails.cache.clear

  def import = @import ||= Import.new(id: 7)

  def draw = ActionController::Base.render(inline: "<%= task_progress_tree import %>", locals: {import:})

  def test_the_railtie_comes_in_with_rails
    assert defined?(TaskProgress::Railtie)
    assert_includes ActionView::Base.ancestors, TaskProgress::TurboHelper
  end

  def test_a_job_broadcasts_its_tree_and_the_page_draws_it
    before = draw
    assert_includes before, "<turbo-cable-stream-source", "subscribed with turbo_stream_from"
    assert_includes before, '<div id="task_progress_import_7" class="tree"></div>', "an empty tree before the first frame"

    TaskProgress.broadcast(import, "Importing", interval: 0.01) do |root|
      root.subtask("Rows", total: 3, cancelable: true) { |t| 3.times { t.tick } }
    end

    stream = Turbo::StreamsChannel.send(:stream_name_from, [import, :task_progress])
    frames = ActionCable.server.pubsub.broadcasts(stream)
    refute_empty frames, "frames went out through Action Cable"
    assert_includes JSON.parse(frames.last), '<turbo-stream action="replace" method="morph" target="task_progress_import_7">'

    after = draw
    assert_includes after, '<div class="row done" id="task_progress_import_7-root"', "the page draws the last frame, from Rails.cache"
    assert_includes after, ">Rows<"
  end

  def test_a_cancel_button_posts_to_the_route_the_railtie_adds
    frames = Queue.new
    worker = Thread.new do
      TaskProgress.broadcast(import, "Importing", interval: 0.01, poll: 0.02,
        to: ->(html) { frames << html }) do |root|
        root.subtask("Rows", cancelable: true) { |t| loop { t.note("tick") && sleep(0.01) } }
        :carried_on
      end
    end
    html = nil
    html = frames.pop until html&.include?("<form")
    assert_includes html, 'action="/task_progress/cancellations"'
    form = {path: html[/name="path" value="([^"]+)"/, 1], token: html[/name="token" value="([^"]+)"/, 1]}

    response = Rack::MockRequest.new(Rails.application).post("/task_progress/cancellations",
      :params => form, "HTTP_ACCEPT" => "text/vnd.turbo-stream.html, text/html")
    assert_equal [200, "text/vnd.turbo-stream.html"], [response.status, response.content_type]
    assert_equal :carried_on, worker.value, "the job picked the request out of Rails.cache, and canceled the task"
    assert_equal 403, Rack::MockRequest.new(Rails.application).post("/task_progress/cancellations", params: form.merge(token: "forged")).status
  end

  def test_a_tree_goes_to_a_job_as_an_argument_and_the_job_is_its_work
    ImportJob.failing = false
    import = TaskProgress.handoff("Importing")
    perform_enqueued_jobs { ImportJob.perform_later(3, import) }
    refute_same import, ImportJob.seen, "it went through the queue, as a key"
    assert_equal import.key, ImportJob.seen.key
    tree = TaskProgress.fetch(import.key)
    assert tree.complete?, "done when perform returned"
    assert_equal [["Rows", 3]], tree.subtasks.map { [it.name, it.count] }
  end

  def test_a_retried_job_starts_its_tree_over
    ImportJob.failing = true
    import = TaskProgress.handoff("Importing")
    perform_enqueued_jobs { ImportJob.perform_later(2, import) }
    tree = TaskProgress.fetch(import.key)
    assert tree.complete?
    assert_equal 2, tree.node.attempt
    assert_equal [["Rows", :done]], tree.subtasks.map { [it.name, it.status] }
  end

  def test_the_polling_recipe
    app = Rack::MockRequest.new(Rails.application)
    perform_enqueued_jobs { assert_equal 202, app.post("/uploads/1").status }
    response = app.get("/uploads/1/progress")
    assert_equal [200, "application/json"], [response.status, response.content_type]
    tree = TaskProgress::Wire.parse(response.body)
    assert_equal ["Importing", "Rows"], tree.events.map { it.value[:name] }
    assert_equal 304, app.get("/uploads/1/progress", "HTTP_IF_NONE_MATCH" => response.headers["etag"]).status
  end

  def test_the_browser_client_is_served_as_it_is
    response = Rack::MockRequest.new(Rails.application).get("/task_progress/js/react_task_tree.js")
    assert_equal 200, response.status
    assert_includes response.body, 'from "./task_tree.js"', "relative imports, which resolve next to it"
  end

  def test_the_sse_recipe
    response = Rack::MockRequest.new(Rails.application).get("/reports/build")
    assert_equal 200, response.status
    assert_equal "text/event-stream", response.content_type
    frames = response.body.scan(/^data: (.*)$/).flatten.map { TaskProgress::Wire.parse(it) }
    state = TaskProgress::State.new
    frames.each { |batch|
      (state = TaskProgress::State.new) if batch.reset?
      batch.events.each { state.apply(it, at: batch.at) }
    }
    assert state.complete?, "streamed to the end"
  end

  def test_a_job_that_never_runs_its_work_leaves_nothing_beating
    import = TaskProgress.handoff("Halting")
    perform_enqueued_jobs { HaltingJob.perform_later(import) }
    tree = TaskProgress.fetch(import.key)
    assert_equal [:failed, "The job stopped before it began its work"], [tree.status, tree.error[:message]]
    assert_nil TaskProgress.stream.get(TaskProgress::StreamOutput.beat_key(import.key)), "and not beating"
  end

  def test_a_task_from_this_process_alone_cannot_go_to_a_job
    assert_raises(ActiveJob::SerializationError) { ImportJob.perform_later(1, TaskProgress.new("local")) }
  end
end
