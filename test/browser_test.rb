require_relative "test_helper"

begin
  require "ferrum"
  require "puma"
  require "rack/mock"
  $LOAD_PATH.unshift File.expand_path("../examples", __dir__)
  require_relative "../examples/web/app"
rescue LoadError
  nil
end

# The bench in a real browser: both renderers following a job, cancel buttons, a stream that is
# cut and resumes, and work grafted from the page. Everything here is what a person would do -
# click a scenario, press a button - and what they would see, read off the page
class BrowserTest < Minitest::Test
  include TestHelpers

  def setup
    skip "ferrum or puma is not installed" unless defined?(Ferrum) && defined?(Puma::Server) && defined?(BenchApp)
    @app = BenchApp.new
    @server = Puma::Server.new(@app, nil, min_threads: 0, max_threads: 32)
    @server.add_tcp_listener("127.0.0.1", 0)
    @server.run
    @base = "http://127.0.0.1:#{@server.connected_ports.first}"
    @browser = BrowserTest.browser
    @browser.reset
    @errors = []
    page.on("Runtime.exceptionThrown") { |params| @errors << params.dig("exceptionDetails", "exception", "description") }
    page.on("Runtime.consoleAPICalled") { |params| @errors << params["args"].map { it["value"] }.join(" ") if params["type"] == "error" }
    page.go_to(@base)
    wait_for { page.at_css(".scenario") }
  rescue Ferrum::BinaryNotFoundError
    skip "there is no Chrome to drive"
  end

  # One Chrome for every test, started once: a cold one on a CI runner can take longer than
  # Ferrum's 10 seconds to come up
  def self.browser
    @browser ||= Ferrum::Browser.new(headless: true, timeout: 15, process_timeout: 60, window_size: [1400, 1000],
      browser_options: {"no-sandbox" => nil}).tap { |browser| Minitest.after_run { browser.quit } }
  end

  def teardown
    # A job still running keeps its streams open, and the server would wait on them to stop
    @app&.jobs&.each { it.root.cancel!("The test is over") }
    @server&.stop(true)
    @app&.jobs&.each { it.thread.kill }
  end

  def page = @browser.page

  def wait_for(timeout: 20, message: "it never happened")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result
      flunk(message) if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def start(scenario, speed: "1")
    page.evaluate("document.getElementById('speed').value = '#{speed}'")
    page.at_css(".scenario[data-id='#{scenario}']").click
    wait_for(message: "#{scenario} never showed up") { rows("#react-tree").any? && rows("#stimulus-tree").any? }
    @app.jobs.max_by(&:number)
  end

  # What a pane shows, row by row: its state and its text
  def rows(pane)
    page.evaluate(<<~JS)
      [...document.querySelectorAll("#{pane} .row")].map((row) => [row.className.replace("row ", ""), row.querySelector(".name").textContent, row.querySelector(".measure").textContent])
    JS
  end

  def row(pane, name) = rows(pane).find { it[1] == name }

  def press_cancel(pane, name)
    page.at_xpath(%(//*[@id="#{pane.delete("#")}"]//div[contains(@class, "row")][.//span[@class="name"][text()="#{name}"]]//button[contains(@class, "cancel")])).click
  end

  def done?(pane) = rows(pane).first&.then { it[0] == "done" && it[2] == "100%" }

  def test_both_renderers_draw_a_job_to_the_end_alike
    job = start("transaction", speed: "4")
    wait_for(message: "the job never finished in both panes") { done?("#stimulus-tree") && done?("#react-tree") }
    assert_equal rows("#stimulus-tree"), rows("#react-tree")
    assert_equal job.root.log.snapshot.size, rows("#stimulus-tree").length, "one row per task"
    assert_empty @errors
  end

  # The third pane is Turbo: HTML the server draws, streamed with TurboSSE, and no client of ours
  def test_the_turbo_pane_ends_up_as_the_other_two(names_and_statuses = ->(pane) { rows(pane).map { it.first(2) } })
    start("transaction", speed: "4")
    wait_for(message: "the Turbo pane never finished") { done?("#turbo-tree") && done?("#stimulus-tree") }
    assert_equal names_and_statuses.call("#stimulus-tree"), names_and_statuses.call("#turbo-tree")
    wait_for(message: "the stream source never took itself off") { page.at_css("#turbo-source").nil? }
    assert_empty @errors
  end

  def test_a_turbo_cancel_button_is_a_form_that_works
    job = start("workers", speed: "0.5")
    wait_for { row("#turbo-tree", "worker 4")&.first == "active" }
    press_cancel("#turbo-tree", "worker 4")
    worker = wait_for { job.root.subtasks.find { it.name == "worker 4" && it.canceled? } }
    assert_equal "Canceled from the browser", worker.message
    wait_for(message: "the cancel never reached the Turbo pane") { row("#turbo-tree", "worker 4")&.first == "canceled" }
    assert_empty @errors
  end

  def test_a_cancel_button_cancels_that_task_on_the_server
    job = start("workers", speed: "0.5")
    wait_for { row("#stimulus-tree", "worker 2")&.first == "active" }
    press_cancel("#stimulus-tree", "worker 2")
    worker = wait_for { job.root.subtasks.find { it.name == "worker 2" && it.canceled? } }
    assert_equal "Canceled from the browser", worker.message
    wait_for(message: "the cancel never came back to both panes") do
      row("#stimulus-tree", "worker 2")&.first == "canceled" && row("#react-tree", "worker 2")&.first == "canceled"
    end
    refute(job.root.subtasks.any? { it.name == "worker 3" && it.canceled? }, "only the task that was asked for")
    press_cancel("#react-tree", "Crunch")
    wait_for { job.root.canceled? }
    assert_empty @errors
  end

  def test_a_cut_stream_resumes_and_ends_up_whole
    page.at_css("#drop").click
    page.evaluate("document.getElementById('drop-after').value = '30'")
    job = start("workers", speed: "4")
    wait_for(timeout: 30, message: "the job never finished in both panes") { done?("#stimulus-tree") && done?("#react-tree") }
    reconnects = page.evaluate(%(document.getElementById("stats").innerText))[/reconnects\s+(\d+)/, 1]
    assert_operator reconnects.to_i, :>, 0, "the stream was cut, and picked up again"
    assert_equal rows("#stimulus-tree"), rows("#react-tree")
    assert_equal job.root.log.snapshot.rows.count, rows("#react-tree").length, "every row, with the finished workers folded"
    assert_empty @errors
  end

  def test_work_grafted_from_the_page_holds_the_job_below_100_until_it_is_through
    job = start("waiting", speed: "4")
    page.evaluate("document.getElementById('speed').value = '0.5'") # the browser's work outlasts the server's
    page.at_css("#graft").click
    wait_for { row("#stimulus-tree", "photos.zip") && row("#react-tree", "photos.zip") }
    press_cancel("#react-tree", "notes.txt")
    wait_for(message: "the server never finished its part") { job.root.finished? }
    wait_for(message: "the end never reached the page") { rows("#stimulus-tree").first[2] == "99%" }
    %w[#stimulus-tree #react-tree].each do |pane|
      assert_equal ["active", "99%"], rows(pane).first.values_at(0, 2), "done on the server, but the browser is still at it"
      assert_equal "canceled", row(pane, "notes.txt")[0], "one graft, drawn in both panes"
    end
    assert_equal :done, job.root.status

    press_cancel("#stimulus-tree", "Hash files in this browser")
    wait_for(message: "canceling the browser's work never let the job finish") { done?("#stimulus-tree") && done?("#react-tree") }
    assert_equal "canceled", row("#react-tree", "video.mp4")[0]
    assert_empty @errors
  end
end
