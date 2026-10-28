# TaskProgress recipes

Whole setups to copy from, start to end. The [README](README.md) has the short version, and the [MANUAL](MANUAL.md) everything else.

- [Relaying a command's progress: ffmpeg](#relaying-a-commands-progress-ffmpeg)
- [A video transcoded in a background job, polled from a Rails page](#a-video-transcoded-in-a-background-job-polled-from-a-rails-page)
- [The same video on an Inertia page, with React](#the-same-video-on-an-inertia-page-with-react)
- [Videos transcoded in subprocesses, drawn in one terminal](#videos-transcoded-in-subprocesses-drawn-in-one-terminal)
- [A Rails action that streams its own progress to React](#a-rails-action-that-streams-its-own-progress-to-react)

Every Rails recipe leans on what the Railtie sets up by itself: the browser client served at `/task_progress/js`, trees as job arguments, and the `task_progress_tree` helper.

## Relaying a command's progress: ffmpeg

Most long work is somebody else's program, and most such programs say how far along they are - ffmpeg among the most talkative. Read what it says, and move a task along with it. The two recipes after this one use it as it is.

```ruby
# lib/transcoder.rb
require "open3"

# Runs ffmpeg, and moves `task` along through the seconds of the input as ffmpeg gets through
# them. ffmpeg writes its progress as key=value lines to wherever `-progress` says - here, its
# stdout. Canceling the task asks ffmpeg to stop, the way a person at its terminal would: with a "q"
module Transcoder
  Failed = Class.new(StandardError)

  def self.run(input, output, task, *options)
    duration = Float(IO.popen(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", input], &:read))
    task.total = duration.ceil
    command = ["ffmpeg", "-hide_banner", "-y", "-i", input, *options, "-progress", "pipe:1", "-nostats", output]
    Open3.popen3(*command) do |stdin, stdout, stderr, wait|
      said = Thread.new { stderr.read rescue "" } # where ffmpeg says what went wrong
      task.on_cancel { stdin.write("q") rescue nil }
      speed = nil
      stdout.each_line do |line|
        key, value = line.chomp.split("=", 2)
        case key
        when "speed" then speed = value.strip
        when "out_time_us"
          seconds = value.to_i / 1_000_000
          task.advance(seconds - task.count, message: ("#{speed} realtime" if speed)) if seconds > task.count
        end
      end
      raise Failed, said.value.lines.last(3).join.strip unless wait.value.success?
    end
  end
end
```

```ruby
TaskProgress.cli("clip.mov") do |root|
  root.subtask("720p", cancelable: true) do |task|
    Transcoder.run("clip.mov", "clip-720p.mp4", task, "-vf", "scale=-2:720", "-c:v", "libx264")
  end
end
```

```
⠋ clip.mov  ██████████████░░░░░░  70%  0.5s
  ⠋ 720p  ██████████████░░░░░░ 14/20  0.5s  15.1x realtime
```

The task counts seconds of video, so the bar comes for free - and after the first second, the rate and the time left too. It finishes by itself at its total. Canceled, ffmpeg is told to stop, and the next `advance` raises `TaskProgress::Canceled`, which ends the work quietly. If ffmpeg fails, the task fails with what ffmpeg last said:

```
✗ clip.mov › 720p: Error opening output /nonexistent/clip-720p.mp4: No such file or directory
```

Anything else that prints its progress goes the same way: `rsync --info=progress2`, `curl --progress-bar`, `pg_restore --verbose`, a `docker build`. Read its lines, find the number, and `advance` or `update(percent)`.

## A video transcoded in a background job, polled from a Rails page

A video is uploaded, a job transcodes it, and the page asks every second how it is doing, with a plain GET - no WebSockets, no SSE, nothing a proxy can get in the way of. Nothing is sent while nothing changes: an unchanged tree is a 304.

**1. Where trees live.** Jobs run in other processes, so the tree goes through Redis:

```ruby
# Gemfile
gem "task_progress"
gem "redis-client"

# config/initializers/task_progress.rb
TaskProgress.stream_store = TaskProgress::RedisStreamStore.new(RedisClient.config(url: ENV.fetch("REDIS_URL", "redis://localhost:6379")).new_pool(size: 10))
```

In development with the `:async` queue adapter, jobs run in the same process as the pages, and you can leave this out - the stream is then kept in memory.

**2. Remember which tree is whose.** A tree is named by its key:

```ruby
add_column :videos, :progress_key, :string
```

**3. Hand the tree to the job.**

```ruby
# app/controllers/videos_controller.rb
class VideosController < ApplicationController
  def create
    video = Video.create!(video_params) # has_one_attached :original, has_many_attached :renditions
    progress = TaskProgress.handoff("Transcoding #{video.original.filename}", cancelable: true)
    video.update!(progress_key: progress.key)
    TranscodeJob.perform_later(video, progress)
    redirect_to video
  end

  def show
    @video = current_user.videos.find(params[:id])
  end
end
```

The tree is pending from the moment it is handed off, so the page shows the video queued before any worker has it. No routes or actions for the progress itself: the Railtie mounts them, and the page gets links to them from `TaskProgress.for_page` - links with a signed token in them, never the tree's key. Handing them out in `show`, which only finds the user's own videos, is the authorization.

**4. Do the work.** The job gets the tree as an argument, already taken up. Its `perform` is the tree's work: done when it returns, failed with the error when it raises. Each size is a task of its own, moved along by [the ffmpeg relay](#relaying-a-commands-progress-ffmpeg):

```ruby
# app/jobs/transcode_job.rb
class TranscodeJob < ApplicationJob
  SIZES = {"1080p" => [], "720p" => ["-vf", "scale=-2:720"], "480p" => ["-vf", "scale=-2:480"]}
  retry_on Transcoder::Failed, attempts: 2

  def perform(video, progress)
    video.original.open do |original|
      SIZES.each do |size, options|
        output = "#{Dir.tmpdir}/#{video.id}-#{size}.mp4"
        progress.subtask(size, weight: 2, cancelable: true) do |task|
          Transcoder.run(original.path, output, task, *options, "-c:v", "libx264", "-preset", "fast")
        end
        progress.subtask("Storing #{size}") { video.renditions.attach(io: File.open(output), filename: "#{size}.mp4") }
      end
    end
  end
end
```

Storing is a task too, without a measure: it counts for little (weight 1 against the transcode's 2) and shows a spinner while it runs. A retry starts the tree over, and the page shows "attempt 2". A worker that dies without a word goes stale on the page after a few seconds, and fails after a minute. Canceling "720p" from the page stops ffmpeg and ends that task - the job goes on with 480p; cancel the root to stop the job, without failing it.

**5. Draw it.**

```ruby
# config/importmap.rb
pin "task_progress/stimulus", to: "/task_progress/js/stimulus_controller.js"
```

```js
// app/javascript/controllers/index.js
import TaskTreeController from "task_progress/stimulus"
application.register("task-tree", TaskTreeController)
```

```erb
<%# app/views/videos/show.html.erb %>
<link rel="stylesheet" href="/task_progress/js/task_tree.css">
<div class="tree" data-controller="task-tree"
     data-task-tree-progress-value="<%= TaskProgress.for_page(@video.progress_key).to_json %>"
     data-task-tree-poll-value="1"></div>
```

The tree is drawn at once, from the snapshot `for_page` puts in. Then it polls every second (`poll-value`), draws once a frame at most, and stops once the video is through. Its cancel buttons ask where `for_page` says.

To have each poll wait for news instead - long polling - set `data-task-tree-wait-value="25"` in place of the poll value; every waiting poll holds a server thread, so size Puma for the pages you expect open at once. Leave both out, and it follows the tree over Server-Sent Events, falling back to polling by itself where those do not get through.

## The same video on an Inertia page, with React

The job and the controller's `create` are [the ones above](#a-video-transcoded-in-a-background-job-polled-from-a-rails-page). What changes is the page: a React component that Inertia renders, and that reloads the video once its renditions are there.

**1. The browser client, from npm.**

```
$ npm install @julik/task-progress
```

It is the same code as the gem's `js/`, at the same version, with TypeScript declarations. React is a peer dependency - the one your app has.

**2. One prop.**

```ruby
# app/controllers/videos_controller.rb
def show
  video = current_user.videos.find(params[:id])
  render inertia: "Videos/Show", props: {
    video: video.as_json(methods: :rendition_urls),
    progress: -> { TaskProgress.for_page(video.progress_key) if video.progress_key }
  }
end
```

`for_page` hands out the links to the tree's events, polling and cancellations - with a signed token in them, good for an hour - and the tree as it stands, for the first render. As a lambda, Inertia leaves it out of a partial reload that does not ask for it.

**3. The component.**

```tsx
// app/frontend/pages/Videos/Show.tsx
import { router } from "@inertiajs/react"
import { TaskTreeView, type Progress } from "@julik/task-progress/react"
import "@julik/task-progress/task_tree.css"

export default function Show({ video, progress }: { video: Video; progress: Progress | null }) {
  return (
    <>
      <VideoPlayer video={video} />
      {progress && (
        <div className="tree">
          <TaskTreeView progress={progress} onComplete={() => router.reload({ only: ["video"] })} />
        </div>
      )}
    </>
  )
}
```

It draws the snapshot straight away - server-side rendering included - follows the tree over Server-Sent Events, and falls back to polling by itself where those do not get through. When the root is done, `onComplete` reloads `video`, and the player has its renditions; `onFail` is there for the other outcome. Navigating away closes the stream.

To draw it your own way - with your design system's components, say - take the rows instead:

```tsx
import { useTaskTree } from "@julik/task-progress/react"

const { rows, cancel } = useTaskTree(progress, { onComplete: () => router.reload({ only: ["video"] }) })
return rows.map((row) => (
  <ProgressRow key={row.key} depth={row.depth} name={row.name} percent={row.percent} striped={row.indeterminate}
    status={row.status} message={row.message} onCancel={row.cancelable ? () => cancel(row) : undefined} />
))
```

## Videos transcoded in subprocesses, drawn in one terminal

A script that transcodes a pile of videos into two sizes each, a few videos at a time, each in a Ruby process of its own - and draws the lot as one tree. Every process reports up a pipe; Ctrl-C cancels everything and stops every ffmpeg, and a process that crashes fails its own branch and the run with it.

**The worker** is an ordinary command-line program, using [the ffmpeg relay](#relaying-a-commands-progress-ffmpeg). Run on its own, it draws its own tree:

```ruby
# transcode.rb
require "task_progress"
require_relative "lib/transcoder"

input = ARGV.fetch(0)
base = File.basename(input, ".*")
TaskProgress.cli(File.basename(input)) do |root|
  root.subtask("1080p", cancelable: true) { |t| Transcoder.run(input, "#{base}-1080p.mp4", t, "-c:v", "libx264", "-preset", "fast") }
  root.subtask("720p", cancelable: true) { |t| Transcoder.run(input, "#{base}-720p.mp4", t, "-vf", "scale=-2:720", "-c:v", "libx264", "-preset", "fast") }
end
```

**The parent** mounts one worker per video. ffmpeg uses several cores of its own, so it runs half as many at once as there are cores:

```ruby
# transcode_all.rb
require "task_progress"
require "etc"

files = ARGV
TaskProgress.cli("Transcode #{files.length} files", cancelable: true) do |root|
  queue = Queue.new
  files.each { queue << [it, root.mount(File.basename(it), cancelable: true)] }
  queue.close

  workers = [Etc.nprocessors / 2, files.length].min.clamp(1, nil).times.map do
    Thread.new do
      while (file, mount = queue.pop)
        mount.spawn(RbConfig.ruby, File.expand_path("transcode.rb", __dir__), file)
      end
    end
  end
  workers.each(&:join)
end
```

```
$ ruby transcode_all.rb *.mov
```

Every video shows from the start, waiting its turn. `TaskProgress.cli` in the worker sees it was started by `spawn` and writes its batches up the pipe instead of drawing; `spawn` returns once the worker exits. On a terminal the tree redraws in place. Piped, or on CI, it writes an execution log instead:

```
[ 10%   0.6s] Transcode 2 files › a.mov › 1080p 4/20
[ 99%   2.4s] ✓ Transcode 2 files › b.mov › 1080p  1.7s
[ 99%   4.7s] ✓ Transcode 2 files › a.mov  4.1s
[ 99%   4.7s] ✓ Transcode 2 files › b.mov  4.1s
[100%   4.7s] ✓ Transcode 2 files  4.1s
```

ffmpeg is a process of its own already, so the relay works from threads in one Ruby process just as well. A Ruby process per video is what to reach for when the Ruby side does real work of its own, or might fall over. Workers on other machines report the same way through Redis: hand each one a tree with `TaskProgress.handoff`, `adopt` it in the worker, and mount it in the parent with `root.mount(name).follow_stream(TaskProgress.stream_store, key)`. `task_progress watch KEY` draws any one of them from yet another terminal.

## A Rails action that streams its own progress to React

A report that takes a minute to build, built while the page watches: the request does the work, and its response is the progress, as Server-Sent Events. Nothing to queue, nothing to store - when the report is ready, the stream ends.

**1. The action.** `ActionController::Live` runs it on a thread of its own and sends what it writes as it writes it. The work goes on another thread, and the stream follows it:

```ruby
# config/routes.rb
get "/reports/:id/build" => "reports#build", as: :build_report

# app/controllers/reports_controller.rb
class ReportsController < ApplicationController
  include ActionController::Live

  def build
    report = Report.find(params[:id])
    response.headers.merge!(TaskProgress::SSE::HEADERS)
    root = TaskProgress.new("Building #{report.name}", cancelable: true)
    work = Thread.new do
      Rails.application.executor.wrap do
        root.run { |r| report.build!(progress: r) }
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
```

```ruby
# app/models/report.rb
def build!(progress:)
  queries = progress.subtask("Queries", total: sections.size)
  sections.each { |section| section.query! && queries.tick }
  progress.subtask("PDF", indeterminate: true) { render_pdf! }
end
```

The tree is sent whole first, then every change as it happens, and the stream ends once the root has finished. A page that goes away is noticed at the next write - a change, or the ping every 15 seconds - and cancels the work. The work is the request's own: each connection builds the report anew, so link to the stream only where you mean to start it. Every open stream holds a Puma thread.

**2. Load the client.**

```
$ bin/importmap pin react react-dom/client
```

```ruby
# config/importmap.rb
pin "task_progress/react", to: "/task_progress/js/react_task_tree.js"
```

**3. Draw it.** In a React app:

```jsx
import { TaskTreeView } from "task_progress/react"

export function ReportBuilder({ report }) {
  const [building, setBuilding] = useState(false)
  if (!building) return <button onClick={() => setBuilding(true)}>Build the report</button>
  return <div className="tree"><TaskTreeView url={`/reports/${report.id}/build`} /></div>
}
```

Or on a page that is not a React app, with no JSX and no build step:

```erb
<link rel="stylesheet" href="/task_progress/js/task_tree.css">
<div class="tree" id="report-progress"></div>
<script type="module">
  import { createTaskTreeRoot } from "task_progress/react"
  createTaskTreeRoot(document.getElementById("report-progress")).render({ url: "<%= build_report_path(@report) %>" })
</script>
```

`useTaskTree(url)` hands you the tree to draw your own way: `tree.rows()` is what to draw, and `rowView(tree, row)` from `row_view.js` what each row says. A tree of thousands of tasks folds what is done and what waits into a row each, so a big report draws as a handful of rows.
