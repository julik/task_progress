import { Controller } from "@hotwired/stimulus"
import { followEventSourceAt } from "./task_tree.js"
import { rowView } from "./row_view.js"

// Draws the tree from a TaskProgress SSE stream. Point it somewhere with the url value:
//   <div data-controller="task-tree" data-task-tree-url-value="/jobs/abc/events"></div>
// Changing the value follows the new stream instead. Draws once a frame at most, and then only
// the rows the batches in that frame touched. Fires task-tree:render after every draw
export default class extends Controller {
  static values = { url: String }

  urlValueChanged(url) {
    this.following?.close()
    this.rows = new Map()
    this.element.replaceChildren()
    if (url) this.following = followEventSourceAt(url, (tree, changes) => this.render(tree, changes))
  }

  disconnect() { this.following?.close() }

  render(tree, changes) {
    if (changes.structure) {
      const rows = new Map()
      for (const node of tree.each()) {
        const k = node.path.join("/")
        rows.set(k, this.rows.get(k) ?? this.#row())
      }
      this.rows = rows
      this.element.replaceChildren(...rows.values())
    }
    for (const node of tree.each()) {
      const k = node.path.join("/")
      // An active row reads the clock for its rate, ETA or elapsed time, so it moves without a batch for it
      if (changes.structure || changes.touched.has(k) || node.status === "active") this.#patch(this.rows.get(k), rowView(tree, node))
    }
    this.dispatch("render", { detail: changes })
  }

  #row() {
    const el = document.createElement("div")
    el.innerHTML = `
      <div class="label"><span class="icon"></span><span class="name"></span><span class="message"></span></div>
      <div class="bar"><span></span></div>
      <div class="measure"></div>`
    el.view = {}
    return el
  }

  // Writes only what differs from the last draw, so an unchanged row costs no DOM work
  #patch(el, row) {
    const last = el.view
    const set = (field, write) => { if (last[field] !== row[field]) write(row[field]) }
    if (last.status !== row.status || last.stale !== row.stale) el.className = `row ${row.status}${row.stale ? " stale" : ""}`
    set("depth", (depth) => { el.querySelector(".label").style.paddingLeft = `${depth * 18}px` })
    set("icon", (icon) => { el.querySelector(".icon").innerHTML = icon })
    set("name", (name) => { el.querySelector(".name").textContent = name })
    set("message", (message) => { el.querySelector(".message").textContent = message })
    set("indeterminate", (on) => { el.querySelector(".bar").classList.toggle("indeterminate", on) })
    set("percent", (percent) => { el.querySelector(".bar span").style.width = `${percent}%` })
    set("measure", (measure) => { el.querySelector(".measure").textContent = measure })
    el.view = row
  }
}
