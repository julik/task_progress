require_relative "test_helper"
require "stringio"

# Drawing a tree as HTML, and sending it where Turbo will pick it up - with no Rails in sight
class TurboTest < Minitest::Test
  include TestHelpers

  def renderer(**) = TaskProgress::HTMLRenderer.new(id: "tree", clock: -> { 1_700_000_100.0 }, **)

  def test_rows_are_drawn_as_the_browser_client_draws_them
    root = TaskProgress.new("Import <all>", log: TaskProgress::Log.new(clock: -> { 1_700_000_000.0 }))
    rows = root.subtask("Rows", total: 10)
    rows.advance!(3, message: "row 3 & on")
    wait = root.subtask("Wait", indeterminate: true)
    wait.note("in line")
    root.subtask("Broken").fail!("disk full")
    html = renderer.render(root.log.snapshot)

    assert html.start_with?('<div id="tree" class="tree"')
    assert_includes html, "Import &lt;all&gt;", "names are escaped"
    assert_includes html, %(<div class="row active" id="tree-#{rows.path.last}" data-path="#{rows.path.last}">)
    assert_includes html, "row 3 &amp; on"
    assert_includes html, '<div class="measure">3 / 10</div>'
    assert_includes html, '<span style="width: 30%"></span>'
    assert_includes html, %(<task-progress-clock started="1700000000.0" drawn="1700000100.0">100.0s</task-progress-clock>), "a running clock"
    assert_includes html, '<div class="bar indeterminate">'
    assert_includes html, '<div class="row failed"'
    assert_includes html, "disk full"
    refute_includes html, "\n", "one line, for SSE and for Turbo"
  end

  def test_a_task_done_with_something_still_open_under_it_is_drawn_running
    root = TaskProgress.new("Root")
    mount = root.mount("Remote")
    TaskProgress.new("remote", outputs: [->(batch, _) { mount << batch }]).subtask("Still going")
    root.done!
    html = renderer.render(root.log.snapshot)
    assert_includes html, '<div class="row active" id="tree-root"'
    assert_includes html, '<div class="measure">99%</div>'
  end

  def test_a_cancelable_task_gets_a_form_and_the_rest_an_empty_column
    root = TaskProgress.new("Root")
    rows = root.subtask("Rows", cancelable: true)
    root.subtask("Plain")
    html = renderer(cancel_url: "/cancel", cancel_token: "t0k&n").render(root.log.snapshot)
    assert_equal 1, html.scan("<form").length
    assert_includes html, %(<form class="cancel-slot" action="/cancel" method="post" data-turbo="true"><input type="hidden" name="path" value="#{rows.path.last}"><input type="hidden" name="token" value="t0k&amp;n">)
    assert_equal 2, html.scan('<span class="cancel-slot"></span>').length
    assert_equal 0, renderer.render(root.log.snapshot).scan("<form").length, "nowhere to post, no button"
  end

  def test_a_branch_is_drawn_as_a_tree_of_its_own
    root = TaskProgress.new("Root")
    branch = root.subtask("Branch")
    branch.subtask("Leaf")
    html = renderer.render(root.log.snapshot, branch.path)
    refute_includes html, ">Root<"
    assert_includes html, 'padding-left: 0px"><span class="icon"><span>·</span></span><span class="name">Branch'
    assert_includes html, 'padding-left: 18px"><span class="icon"><span>·</span></span><span class="name">Leaf'
  end

  def test_the_output_broadcasts_the_whole_tree_and_keeps_the_last_frame
    frames = []
    store = TaskProgress::MemoryStore.new
    output = TaskProgress::TurboStreamOutput.new(renderer:, broadcast: ->(html) { frames << html }, store:)
    root = TaskProgress.new("Root", outputs: [output])
    root.subtask("Rows").done!
    assert_equal root.log.seq, frames.length
    assert frames.last.start_with?('<turbo-stream action="replace" method="morph" target="tree"><template><div id="tree"')
    assert_includes frames.last, ">Rows<"
    assert_equal frames.last[/<template>(.*)<\/template>/, 1], store.read("task_progress/tree")
  end

  def test_broadcast_draws_a_few_frames_however_spammy_the_work
    frames = []
    result = TaskProgress.broadcast("tree", "Crunch", broadcast: ->(html) { frames << html }, interval: 0.05) do |r|
      r.subtask("Items", total: 2000) { |t| 2000.times { t.tick! } }
      :crunched
    end
    assert_operator frames.length, :<, 50, "squashed, not one a tick"
    assert_includes frames.last, '<div class="row done" id="tree-root"'
    assert_equal :crunched, result, "the block's value, as with cli"
  end

  def test_broadcast_needs_somewhere_to_send_frames_outside_rails
    assert_raises(ArgumentError) { TaskProgress.broadcast("tree", "Lost") }
  end

  def test_a_cancel_button_reaches_a_job_through_the_store
    store = TaskProgress::MemoryStore.new
    tokens = TaskProgress::CancelToken.new("s" * 32)
    app = TaskProgress::CancellationsApp.new(store:, tokens:)
    frames = Queue.new
    worker = Thread.new do
      TaskProgress.broadcast("job-1", "Job", broadcast: ->(html) { frames << html }, store:, tokens:, cancel_url: "/cancel", interval: 0.01, poll: 0.02) do |root|
        root.subtask("Rows", cancelable: true) { |t| loop { t.note("tick") && sleep(0.01) } }
        :carried_on
      end
    end
    html = nil
    html = frames.pop until html&.include?("<form")
    token = html[/name="token" value="([^"]+)"/, 1]
    path = html[/name="path" value="([^"]+)"/, 1]

    status, headers, = app.call(env(path:, token:, accept: "text/vnd.turbo-stream.html, text/html"))
    assert_equal [200, "text/vnd.turbo-stream.html"], [status, headers["content-type"]], "a Turbo form gets an empty stream"
    assert_equal :carried_on, worker.value, "the job saw the request, and canceled the task"
    assert_nil store.read(TaskProgress::CancellationsApp.request_key("task_progress/job-1", [path])), "taken up, and gone"
    assert_includes store.read("task_progress/job-1"), '<div class="row canceled"'
  end

  def test_the_cancellations_app_turns_away_what_it_should
    app = TaskProgress::CancellationsApp.new(store: TaskProgress::MemoryStore.new, tokens: TaskProgress::CancelToken.new("s" * 32))
    token = TaskProgress::CancelToken.new("s" * 32).issue("task_progress/x")
    assert_equal 403, app.call(env(path: "abcd", token: "forged")).first
    assert_equal 403, app.call(env(path: "abcd", token: TaskProgress::CancelToken.new("t" * 32).issue("task_progress/x"))).first
    assert_equal 422, app.call(env(path: "Not A Path", token:)).first
    assert_equal 405, app.call({"REQUEST_METHOD" => "GET"}).first
    status, _, body = app.call(env(path: "abcd", token:, json: true))
    assert_equal [202, {"path" => "abcd", "state" => "requested"}], [status, JSON.parse(body.first)]
  end

  def test_turbo_sse_streams_frames_and_stops_the_source_at_the_end
    root = TaskProgress.new("Root")
    rows = root.subtask("Rows", total: 3)
    chunks = Queue.new
    reader = Thread.new { TaskProgress::TurboSSE.new(root, renderer:, interval: 0.01, source: "src").each { chunks << it } }
    sleep 0.05
    3.times { rows.tick! }
    root.done!
    reader.join(2)
    all = [].tap { |a| a << chunks.pop until chunks.empty? }
    assert_equal "retry: 2000\n\n", all.first
    frames = all.select { it.start_with?("data: <turbo-stream action=\"replace\"") }
    assert_operator frames.length, :>=, 2
    assert_includes frames.last, '<div class="row done" id="tree-root"'
    assert_equal %(data: <turbo-stream action="remove" target="src"></turbo-stream>\n\n), all.last
    assert(all.all? { it.end_with?("\n\n") })
  end

  private

  def env(path:, token:, accept: "application/json", json: false)
    body = json ? JSON.generate(path:, token:) : URI.encode_www_form(path:, token:)
    {"REQUEST_METHOD" => "POST", "CONTENT_TYPE" => json ? "application/json" : "application/x-www-form-urlencoded",
     "HTTP_ACCEPT" => accept, "rack.input" => StringIO.new(body)}
  end
end
