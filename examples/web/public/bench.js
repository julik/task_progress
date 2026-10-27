import { Application } from "@hotwired/stimulus"
import TaskTreeController from "/task_progress/stimulus_controller.js"
import { mountTaskTree } from "/task_progress/react_task_tree.js"
import { TaskTree } from "/task_progress/task_tree.js"
import { nextFrame } from "/task_progress/render_queue.js"

Application.start().register("task-tree", TaskTreeController)
const react = mountTaskTree(document.getElementById("react-tree"))
const $ = (id) => document.getElementById(id)

let scenarios = []
let current = null

async function loadScenarios() {
  scenarios = await (await fetch("/scenarios")).json()
  $("scenarios").replaceChildren(...scenarios.map((scenario) => {
    const button = document.createElement("button")
    button.className = "scenario"
    button.dataset.id = scenario.id
    button.innerHTML = "<strong></strong><span></span>"
    button.querySelector("strong").textContent = scenario.title
    button.querySelector("span").textContent = scenario.description
    button.addEventListener("click", () => start(scenario.id))
    return button
  }))
}

async function start(id) {
  const response = await fetch(`/jobs?scenario=${id}&speed=${$("speed").value}`, { method: "POST" })
  watch(await response.json())
  refreshJobs()
}

function streamUrl(job) {
  return $("drop").checked ? `${job.events}?drop_after=${$("drop-after").value}` : job.events
}

// Both renderers and the inspector follow the same job, each on a stream of its own
function watch(job) {
  current = job
  const scenario = scenarios.find((s) => s.id === job.scenario)
  $("job-title").textContent = scenario?.title ?? job.scenario
  $("job-meta").textContent = `job ${job.id} · ${streamUrl(job)}`
  $("cancel").hidden = false
  document.querySelectorAll(".scenario").forEach((b) => b.classList.toggle("current", b.dataset.id === job.scenario))
  const url = streamUrl(job)
  $("stimulus-tree").dataset.taskTreeCancelUrlValue = `/jobs/${job.id}/cancel`
  $("stimulus-tree").dataset.taskTreeUrlValue = url
  react.followEventSourceAt(url, { cancelUrl: `/jobs/${job.id}/cancel` })
  inspector.follow(url)
}

$("cancel").addEventListener("click", async () => {
  if (current) await fetch(`/jobs/${current.id}/cancel`, { method: "POST" })
  refreshJobs()
})

async function refreshJobs() {
  const jobs = await (await fetch("/jobs")).json()
  if (jobs.length === 0) return
  $("jobs").replaceChildren(...jobs.map((job) => {
    const row = document.createElement("div")
    row.className = "job-row"
    row.innerHTML = `<span><span class="title"></span> <span class="status-${job.status}">${job.status} ${job.percent}%</span></span><button class="secondary">Watch</button>`
    row.querySelector(".title").textContent = scenarios.find((s) => s.id === job.scenario)?.title ?? job.scenario
    row.querySelector("button").addEventListener("click", () => watch(job))
    return row
  }))
}

// Reads the stream at the level of batches: what arrived, how it chained, and how often the
// connection had to start over. It counts every batch, but like the renderers it only touches
// the page once a frame. The renders are the Stimulus pane's, to show how many batches each draw took in
const inspector = {
  source: null,
  follow(url) {
    this.source?.close()
    this.tree = new TaskTree()
    this.stats = { frames: 0, ops: 0, resets: 0, gaps: 0, duplicates: 0, reconnects: 0, seq: "–", "batches/s": 0, renders: 0, "renders/s": 0, root: "–" }
    this.opens = 0
    this.times = []
    this.renders = []
    this.lines = []
    $("log").replaceChildren()
    this.render()
    this.source = new EventSource(url)
    this.source.addEventListener("open", () => {
      if (this.opens++ > 0) { this.stats.reconnects++; this.line("reconnected - expecting a fresh squash", "reconnect") }
    })
    this.source.addEventListener("batch", (event) => this.batch(JSON.parse(event.data), event.data.length))
  },
  batch(batch, bytes) {
    const result = this.tree.apply(batch)
    const now = performance.now()
    this.times = this.times.filter((t) => now - t < 1000).concat(now)
    Object.assign(this.stats, { frames: this.stats.frames + 1, ops: this.stats.ops + batch.ops.length, seq: batch.seq, "batches/s": this.times.length })
    if (batch.prev === 0) this.stats.resets++
    if (result === "gap") this.stats.gaps++
    if (result === "duplicate") this.stats.duplicates++
    const root = this.tree.root
    if (root) this.stats.root = `${root.status} ${this.tree.percentOf(root)}%`
    const counts = {}
    for (const [, op] of batch.ops) counts[op] = (counts[op] ?? 0) + 1
    const summary = Object.entries(counts).map(([op, n]) => (n > 1 ? `${op}×${n}` : op)).join(" ")
    const kind = batch.prev === 0 ? "reset" : result === "applied" ? "" : result
    this.line(`#${batch.seq} ← ${batch.prev}  ${bytes}B  ${summary}${kind ? `  (${kind})` : ""}`, kind)
    if (root && (root.status === "done" || root.status === "failed")) {
      this.source.close()
      this.line(`stream closed: root ${root.status}`, "")
      refreshJobs()
    }
  },
  rendered() {
    const now = performance.now()
    this.renders = this.renders.filter((t) => now - t < 1000).concat(now)
    Object.assign(this.stats, { renders: this.stats.renders + 1, "renders/s": this.renders.length })
    this.request()
  },
  line(text, kind) {
    this.lines.push([text, kind])
    this.request()
  },
  request() {
    if (this.pending) return
    this.pending = true
    nextFrame(() => { this.pending = false; this.flush() })
  },
  // Only the last 300 lines are kept, so a frame never builds more than that
  flush() {
    const log = $("log")
    log.prepend(...this.lines.slice(-300).reverse().map(([text, kind]) => {
      const li = document.createElement("li")
      li.textContent = text
      if (kind) li.className = kind
      return li
    }))
    this.lines = []
    while (log.children.length > 300) log.lastChild.remove()
    this.render()
  },
  render() {
    $("stats").replaceChildren(...Object.entries(this.stats).map(([name, value]) => {
      const div = document.createElement("div")
      if ((name === "gaps" && value > 0)) div.className = "bad"
      div.innerHTML = "<dt></dt><dd></dd>"
      div.querySelector("dt").textContent = name
      div.querySelector("dd").textContent = value
      return div
    }))
  }
}

$("stimulus-tree").addEventListener("task-tree:render", () => inspector.rendered())

await loadScenarios()
refreshJobs()
setInterval(refreshJobs, 3000)
