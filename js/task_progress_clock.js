// <task-progress-clock started="…" drawn="…" [finished="…"]> - an elapsed time that ticks on
// between the frames a server sends (see TaskProgress::HTMLRenderer), so a page drawn a few
// times a second, or less, still counts the seconds. Its times are the server's: `drawn` is when
// the server drew it, and the time since then is measured here, so the two clocks never have to
// agree. A finished one stands still. Import this module once on the page, and the element
// does the rest

export class TaskProgressClock extends HTMLElement {
  static observedAttributes = ["started", "drawn", "finished"]

  connectedCallback() {
    this.#sync()
    this.timer = setInterval(() => this.#tick(), 100)
  }

  disconnectedCallback() { clearInterval(this.timer) }

  // A morph that redraws the tree changes the attributes, and the clock starts over from them
  attributeChangedCallback() { this.#sync() }

  #sync() { this.syncedAt = performance.now() / 1000 }

  #tick() {
    const started = Number(this.getAttribute("started"))
    if (!started) return
    const finished = this.getAttribute("finished")
    const now = finished ? Number(finished) : Number(this.getAttribute("drawn")) + (performance.now() / 1000 - this.syncedAt)
    const text = `${Math.max(0, now - started).toFixed(1)}s`
    if (this.textContent !== text) this.textContent = text
  }
}

if (!customElements.get("task-progress-clock")) customElements.define("task-progress-clock", TaskProgressClock)
