require_relative "test_helper"

require "timeout"

begin
  require "rack/mock"
  $LOAD_PATH.unshift File.expand_path("../examples", __dir__)
  require_relative "../examples/web/app"
rescue LoadError
  nil
end

# The bench behind bin/dev, driven the way its page drives it - so every scenario there is
# known to run to the end, and to stream a tree that folds without a gap
class BenchAppTest < Minitest::Test
  include TestHelpers

  def setup
    skip "rack is not installed" unless defined?(BenchApp)
    @app = BenchApp.new
    @request = Rack::MockRequest.new(@app)
  end

  def start(scenario, speed: 50)
    response = @request.post("/jobs?scenario=#{scenario}&speed=#{speed}")
    assert_equal 201, response.status, response.body
    JSON.parse(response.body)
  end

  # A scenario that never finishes would stream forever, so it gets a deadline
  def batches(path)
    body = Timeout.timeout(30, Minitest::Assertion, "#{path} never finished") { @request.get(path).body }
    body.scan(/^data: (.*)$/).flatten.map { TaskProgress::Wire.parse(it) }
  end

  def test_every_scenario_runs_and_streams_a_whole_tree
    Scenarios::ALL.each do |scenario|
      job = start(scenario.id)
      streamed = batches(job["events"])
      root = @app.jobs.find { it.id == job["id"] }.root
      assert streamed.first.reset?, scenario.id
      assert(streamed.each_cons(2).all? { |a, b| b.prev == a.seq }, "#{scenario.id} streamed with a gap")
      assert root.finished?, "#{scenario.id} did not finish"
      assert_equal root.log.snapshot.to_h, fold_batches(streamed).to_h, scenario.id
    end
  end

  def test_the_failing_import_fails_with_the_engines_error
    job = start("import_fails")
    batches(job["events"])
    root = @app.jobs.find { it.id == job["id"] }.root
    assert_equal :failed, root.status
    assert_match(/Simulated failure/, root.error[:message])
  end

  def test_cancel_fails_the_job_with_an_interrupt
    job = start("waiting", speed: 1)
    sleep 0.2
    assert_equal 200, @request.post("/jobs/#{job["id"]}/cancel").status
    batches(job["events"])
    root = @app.jobs.find { it.id == job["id"] }.root
    assert_equal :failed, root.status
    assert_equal "Interrupt", root.error[:class]
  end

  def test_a_cut_stream_stops_after_so_many_frames
    job = start("workers", speed: 5)
    assert_equal 10, batches("#{job["events"]}?drop_after=10").length
  end

  def test_jobs_list_newest_first_by_the_order_they_started
    ids = 3.times.map { start("deep")["id"] }
    listed = JSON.parse(@request.get("/jobs").body).map { it["id"] }
    assert_equal ids.reverse, listed.first(3)
  end

  def test_listings_and_unknowns
    assert_equal Scenarios::ALL.map(&:id), JSON.parse(@request.get("/scenarios").body).map { it["id"] }
    job = start("deep")
    assert_includes JSON.parse(@request.get("/jobs").body).map { it["id"] }, job["id"]
    assert_equal 404, @request.post("/jobs?scenario=nope").status
    assert_equal 404, @request.get("/jobs/nope/events").status
    assert_equal 302, @request.get("/").status
    assert_equal 200, @request.get("/index.html").status
  end
end
