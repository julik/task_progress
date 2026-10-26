import { Controller } from "@hotwired/stimulus"
import { follow } from "/task_tree.js"
import { rowView } from "/row_view.js"

// Draws the tree from a TaskProgress SSE stream. Point it somewhere with the url value:
//   <div data-controller="task-tree" data-task-tree-url-value="/jobs/abc/events"></div>
// Changing the value follows the new stream instead
export default class extends Controller {
  static values = { url: String }

  urlValueChanged(url) {
    this.following?.close()
    this.element.replaceChildren()
    if (url) this.following = follow(url, (tree) => this.render(tree))
  }

  disconnect() { this.following?.close() }

  render(tree) {
    this.element.replaceChildren(...[...tree.each()].map((node) => this.#row(rowView(tree, node))))
  }

  #row(row) {
    const el = document.createElement("div")
    el.className = `row ${row.status}${row.stale ? " stale" : ""}`
    el.innerHTML = `
      <div class="label" style="padding-left:${row.depth * 18}px">
        <span class="icon"></span><span class="name"></span><span class="message"></span>
      </div>
      <div class="bar${row.indeterminate ? " indeterminate" : ""}"><span style="width:${row.percent}%"></span></div>
      <div class="measure"></div>`
    el.querySelector(".icon").innerHTML = row.icon
    el.querySelector(".name").textContent = row.name
    el.querySelector(".message").textContent = row.message
    el.querySelector(".measure").textContent = row.measure
    return el
  }
}
