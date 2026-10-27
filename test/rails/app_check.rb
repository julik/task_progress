# A Rails app of the smallest kind, with TaskProgress in it - run in a process of its own by
# test/rails_test.rb, so that Rails never leaks into the tests that prove the gem needs none
require "bundler/setup"
require "logger"
require "rails"
require "action_controller/railtie"
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

class RailsAppCheck < Minitest::Test
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
      root.subtask("Rows", total: 3, cancelable: true) { |t| 3.times { t.tick! } }
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
        broadcast: ->(html) { frames << html }) do |root|
        root.subtask("Rows", cancelable: true) { |t| loop { t.note("tick") && sleep(0.01) } }
        :carried_on
      end
    end
    html = nil
    html = frames.pop until html&.include?("<form")
    assert_includes html, 'action="/task_progress/cancellations"'
    form = {path: html[/name="path" value="([^"]+)"/, 1], token: html[/name="token" value="([^"]+)"/, 1]}

    response = Rack::MockRequest.new(Rails.application).post("/task_progress/cancellations",
      params: form, "HTTP_ACCEPT" => "text/vnd.turbo-stream.html, text/html")
    assert_equal [200, "text/vnd.turbo-stream.html"], [response.status, response.content_type]
    assert_equal :carried_on, worker.value, "the job picked the request out of Rails.cache, and canceled the task"
    assert_equal 403, Rack::MockRequest.new(Rails.application).post("/task_progress/cancellations", params: form.merge(token: "forged")).status
  end
end
