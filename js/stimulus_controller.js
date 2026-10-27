import { Controller } from "@hotwired/stimulus"
import { followEventSourceAt, followPollingAt, requestCancel, pathKey } from "./task_tree.js"
import { rowView, CANCEL_ICON } from "./row_view.js"

// Draws the tree from a TaskProgress SSE stream. Point it somewhere with the url value:
//   <div data-controller="task-tree" data-task-tree-url-value="/jobs/abc/events"></div>
// Changing the value follows the new stream instead. Where SSE does not get through, point it at
// a TaskProgress::Poll endpoint and give it a poll value - seconds between polls - and a wait
// value to long-poll instead. Draws once a frame at most, and then only
// the rows the batches in that frame touched. Fires task-tree:render after every draw.
//
// A cancelable task gets a cancel button. Pressing it fires task-tree:cancel with the task's
// path, and - unless that is prevented - creates a cancellation at the cancel-url value, if there
// is one, signed with the cancel-token value. A task running in this browser is canceled here.
//
// `graft(path, localTasks)` draws tasks running in this browser under a server task, until the
// url value changes - see TaskTree#graft. Reach the controller with
// application.getControllerForElementAndIdentifier(element, "task-tree")
export default class extends Controller {
  static values = { url: String, cancelUrl: String, cancelToken: String, poll: Number, wait: Number }

  urlValueChanged(url) {
    this.#stop()
    this.rows = new Map()
    this.keys = null
    this.element.replaceChildren()
    if (!url) return
    const draw = (tree, changes) => this.render(tree, changes)
    this.following = this.pollValue || this.waitValue
      ? followPollingAt(url, draw, { interval: (this.pollValue || 1) * 1000, wait: this.waitValue })
      : followEventSourceAt(url, draw)
  }

  disconnect() { this.#stop() }

  graft(path, local) {
    if (this.following) this.ungrafts.push(this.following.tree.graft(path, local))
  }

  #stop() {
    for (const ungraft of this.ungrafts ?? []) ungraft()
    this.ungrafts = []
    this.following?.close()
  }

  render(tree, changes) {
    const shown = [...tree.rows()]
    // A task finishing can fold it away, so which rows there are is checked every time, not only when tasks come and go
    const keys = shown.map((node) => pathKey(node.path)).join(" ")
    const rebuilt = changes.structure || keys !== this.keys
    if (rebuilt) {
      const rows = new Map()
      for (const node of shown) {
        const k = pathKey(node.path)
        rows.set(k, this.rows.get(k) ?? this.#row())
      }
      this.rows = rows
      this.keys = keys
      this.element.replaceChildren(...rows.values())
    }
    for (const node of shown) {
      const k = pathKey(node.path)
      // An active row reads the clock for its rate, ETA or elapsed time, so it moves without a batch for it
      if (rebuilt || node.fold || changes.touched.has(k) || node.status === "active") this.#patch(this.rows.get(k), rowView(tree, node))
    }
    this.dispatch("render", { detail: changes })
  }

  #row() {
    const el = document.createElement("div")
    el.innerHTML = `
      <div class="label"><span class="icon"></span><span class="name"></span><span class="message"></span></div>
      <div class="bar"><span></span></div>
      <button type="button" class="cancel" hidden>${CANCEL_ICON}</button>
      <div class="measure"></div>`
    el.view = {}
    el.querySelector(".cancel").addEventListener("click", (event) => this.#cancel(event.currentTarget, el.view))
    return el
  }

  #cancel(button, row) {
    const { defaultPrevented } = this.dispatch("cancel", { detail: { path: row.path, name: row.name }, cancelable: true })
    if (defaultPrevented) return
    if (row.local) return this.following?.tree.cancelLocal(row.path, "Canceled in this browser")
    if (!this.cancelUrlValue) return
    button.disabled = true // until the cancel comes down the stream, or the server says no
    requestCancel(this.cancelUrlValue, row.path, { token: this.cancelTokenValue })
      .then((response) => { if (!response.ok) button.disabled = false }, () => { button.disabled = false })
  }

  // Writes only what differs from the last draw, so an unchanged row costs no DOM work
  #patch(el, row) {
    const last = el.view
    const set = (field, write) => { if (last[field] !== row[field]) write(row[field]) }
    if (last.status !== row.status || last.stale !== row.stale || last.folded !== row.folded) {
      el.className = `row ${row.status}${row.stale ? " stale" : ""}${row.folded ? " folded" : ""}`
    }
    set("depth", (depth) => { el.querySelector(".label").style.paddingLeft = `${depth * 18}px` })
    set("icon", (icon) => { el.querySelector(".icon").innerHTML = icon })
    set("name", (name) => { el.querySelector(".name").textContent = name })
    set("message", (message) => { el.querySelector(".message").textContent = message })
    set("indeterminate", (on) => { el.querySelector(".bar").classList.toggle("indeterminate", on) })
    set("percent", (percent) => { el.querySelector(".bar span").style.width = `${percent}%` })
    set("measure", (measure) => { el.querySelector(".measure").textContent = measure })
    set("cancelable", (on) => {
      const button = el.querySelector(".cancel")
      button.hidden = !on
      button.disabled = false
    })
    set("name", (name) => { el.querySelector(".cancel").setAttribute("aria-label", `Cancel ${name}`) })
    el.view = row
  }
}
