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

  def test_cancel_cancels_the_job
    job = start("waiting", speed: 1)
    sleep 0.2
    assert_equal 200, @request.post("/jobs/#{job["id"]}/cancel").status
    batches(job["events"])
    root = @app.jobs.find { it.id == job["id"] }.root
    assert_equal :canceled, root.status
    assert_equal "Cancelled from the bench", root.message
  end

  def cancellation(job, path, token: job["cancel_token"])
    response = @request.post(job["cancellations"], "CONTENT_TYPE" => "application/json", input: JSON.generate(path:, token:))
    [response.status, (JSON.parse(response.body) rescue nil), response.headers["location"]]
  end

  def test_a_cancellation_is_created_for_a_cancelable_task
    job = start("workers", speed: 0.5)
    root = @app.jobs.find { it.id == job["id"] }.root
    sleep 0.01 until (worker = root.subtasks.first)
    key = worker.path.join("-")

    status, body, location = cancellation(job, key)
    assert_equal [201, "canceled", key], [status, body["state"], body["path"]]
    assert_equal :canceled, worker.status
    assert_equal "Canceled from the browser", worker.message
    assert_equal({"state" => "canceled"}, JSON.parse(@request.get(location).body).slice("state"))

    status, again, = cancellation(job, key)
    assert_equal [200, body], [status, again], "asking again gives back the same cancellation"

    plain = root.subtasks.last
    assert_equal 409, cancellation(job, plain.path.join("-")).first if !plain.cancelable? && !plain.finished?
    assert_equal 422, cancellation(job, "Not-A Path").first
    cancellation(job, "")
    batches(job["events"])
    assert_equal :canceled, root.status
  end

  def test_a_cancellation_needs_the_jobs_own_token
    job = start("workers", speed: 0.5)
    other = start("workers", speed: 0.5)
    assert_equal 403, cancellation(job, "", token: nil).first
    assert_equal 403, cancellation(job, "", token: "#{job["cancel_token"]}x").first, "a mangled signature"
    assert_equal 403, cancellation(job, "", token: other["cancel_token"]).first, "another job's token"
    form = @request.post(job["cancellations"], params: {path: "", token: "nope"})
    assert_equal 403, form.status
    [job, other].each { cancellation(it, "") }
  end

  def test_a_cancellation_that_comes_too_late_is_moot_and_quiet
    job = start("transaction", speed: 50)
    batches(job["events"])
    root = @app.jobs.find { it.id == job["id"] }.root
    status, body, = cancellation(job, "")
    assert_equal [201, "moot"], [status, body["state"]], "the job finished first, which is no error"

    @app.instance_variable_get(:@jobs).delete(job["id"])
    status, body, = cancellation(job, root.subtasks.first.path.join("-"))
    assert_equal [201, "moot"], [status, body["state"]], "nor is a job that is gone"
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
    assert_equal 200, @request.get("/").status
  end

  # Every asset the page links has to be served at the URL it was linked as - a stale ?s= or a
  # file left behind in a move would leave the page without its scripts
  def test_the_page_links_assets_that_are_served
    page = @request.get("/").body
    links = page.scan(/(?:href|src)="(\/[^"]+\?s=\w+)"/).flatten
    assert_operator links.length, :>=, 8
    links.each { assert_equal 200, @request.get(it).status, it }
    assert_includes links.join, "/task_progress/task_tree.js"
  end
end
