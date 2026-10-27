// Tasks that run in this browser - hashing files before an upload, say - written the way the
// server writes its own: every change a batch, numbered, folded into a tree. Graft them under a
// server task with TaskTree#graft and the renderers draw them as its children.
//
//   const work = new LocalTasks("Hash files", { cancelable: true })
//   tree.graft(serverTask.path, work)
//   const file = work.root.subtask("video.mp4", { total: blob.size, unit: "bytes" })
//   file.onCancel(() => controller.abort())
//   file.advance(chunk.byteLength)
//
// The rules are the server's: a counted task is done at its total, done() closes everything
// still open under it, fail() and cancel() cancel it. Changing a task that has ended does
// nothing - check `canceled` in loops that would otherwise carry on.
//
// Ids start with "_", which a server id never does, so a graft cannot clash with the tree it
// is grafted to, and a task can tell it runs here.

import { TaskTree } from "./task_tree.js"

const FINISHED = new Set(["done", "failed", "canceled"])
const randomId = (length) => "_" + Array.from({ length }, () => Math.floor(Math.random() * 36).toString(36)).join("")

const attributes = ({ name, total, weight, expect, indeterminate, unit, cancelable }) =>
  Object.fromEntries(Object.entries({ name, total, weight, expect, indeterminate: indeterminate || undefined, unit, cancelable: cancelable || undefined })
    .filter(([, value]) => value !== undefined && value !== null))

export class LocalTasks {
  constructor(name, { clock = () => Date.now() / 1000, autofinish = true, ...options } = {}) {
    this.log = randomId(10)
    this.seq = 0
    this.clock = clock
    this.tree = new TaskTree({ clock })
    this.listeners = new Set()
    this.handlers = new Map() // key -> [onCancel callbacks]
    this.waiting = new Map() // key -> [whenFinished resolvers]
    this.signals = new Map() // key -> AbortSignal, made on first ask
    this.autofinish = new Map()
    this.commit([[[], "open", attributes({ name, ...options })]])
    this.autofinish.set("", autofinish)
    this.root = new LocalTask(this, [])
  }

  // Calls fn(batch) with every batch from now on. Returns a function that stops it
  subscribe(fn) {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }

  // The tree so far as one batch of puts, prev 0 - what a graft starts from
  squash() {
    const ops = [...this.tree.each()].map((node) => [node.path, "put", putValue(node)])
    return { v: 1, log: this.log, prev: 0, seq: this.seq, at: this.clock(), ops }
  }

  commit(ops) {
    if (ops.length === 0) return
    const batch = { v: 1, log: this.log, prev: this.seq, seq: this.seq + 1, at: this.clock(), ops }
    this.tree.apply(batch)
    this.seq = batch.seq
    for (const listener of this.listeners) listener(batch)
    for (const [path, op, reason] of ops) {
      if (op !== "cancel" && op !== "done" && op !== "fail") continue
      const key = path.join("-")
      const handlers = this.handlers.get(key) ?? []
      this.handlers.delete(key)
      if (op === "cancel") for (const handler of handlers) handler(reason ?? null)
      for (const resolve of this.waiting.get(key) ?? []) resolve(this.tree.get(path).status)
      this.waiting.delete(key)
    }
  }

  newId() {
    let id
    do id = randomId(4)
    while ([...this.tree.nodes.values()].some((node) => node.path[node.path.length - 1] === id))
    return id
  }

  // The task at `path`, or null
  at(path) { return this.tree.get(path) ? new LocalTask(this, path) : null }

  // Every task under `path` still open, deepest first
  openUnder(path) {
    const node = this.tree.get(path)
    return [...this.tree.each(node)].slice(1).filter((n) => !FINISHED.has(n.status)).map((n) => n.path).reverse()
  }
}

class LocalTask {
  constructor(tasks, path) {
    this.tasks = tasks
    this.path = path
  }

  get node() { return this.tasks.tree.get(this.path) }
  get status() { return this.node.status }
  get finished() { return FINISHED.has(this.status) }
  get canceled() { return this.status === "canceled" }

  subtask(name, { autofinish = true, ...options } = {}) {
    if (this.finished) return null
    const path = [...this.path, this.tasks.newId()]
    this.tasks.commit([[path, "open", attributes({ name, ...options })]])
    this.tasks.autofinish.set(path.join("-"), autofinish)
    return new LocalTask(this.tasks, path)
  }

  advance(by = 1, { message } = {}) {
    if (this.finished) return this
    const ops = [[this.path, "add", by]]
    if (message != null) ops.push([this.path, "note", message])
    const { count, total } = this.node
    if (this.tasks.autofinish.get(this.path.join("-")) && total != null && count + by >= total) ops.push(...this.#closing("done"))
    this.tasks.commit(ops)
    return this
  }

  tick(options) { return this.advance(1, options) }

  update(percent, { message } = {}) {
    if (this.finished) return this
    const ops = message != null ? [[this.path, "note", message]] : []
    ops.push(...(percent >= 100 ? this.#closing("done") : [[this.path, "set", percent]]))
    this.tasks.commit(ops)
    return this
  }

  note(message) {
    if (!this.finished) this.tasks.commit([[this.path, "note", message]])
    return this
  }

  // An AbortSignal that aborts, with the reason, once this task is canceled. Nothing is wired
  // to it: a cancel stops only what you hand it to - `fetch(url, { signal: task.signal })`
  get signal() {
    const key = this.path.join("-")
    if (!this.tasks.signals.has(key)) {
      const controller = new AbortController()
      this.tasks.signals.set(key, controller.signal)
      this.onCancel((reason) => controller.abort(reason ?? "Canceled"))
    }
    return this.tasks.signals.get(key)
  }

  // Resolves with "done", "failed" or "canceled" once the task ends - at once, if it has
  whenFinished() {
    if (this.finished) return Promise.resolve(this.status)
    const key = this.path.join("-")
    return new Promise((resolve) => this.tasks.waiting.set(key, [...(this.tasks.waiting.get(key) ?? []), resolve]))
  }

  // For a total only learned once the work has started - the size of an upload, say
  setTotal(total) {
    if (!this.finished) this.tasks.commit([[this.path, "meta", { total }]])
    return this
  }

  done() {
    if (!this.finished) this.tasks.commit(this.#closing("done"))
    return this
  }

  fail(error) {
    if (this.finished) return this
    const value = { class: error?.name ?? "Error", message: String(error?.message ?? error ?? `${this.node.name} failed`) }
    this.tasks.commit([...this.tasks.openUnder(this.path).map((path) => [path, "cancel"]), [this.path, "fail", value]])
    return this
  }

  cancel(reason) {
    if (!this.finished) this.tasks.commit(this.#closing("cancel", reason))
    return this
  }

  // Runs once this task is canceled - at once, if it already was. Hook an AbortController here
  onCancel(handler) {
    if (this.canceled) handler(this.node.message)
    else if (!this.finished) {
      const key = this.path.join("-")
      this.tasks.handlers.set(key, [...(this.tasks.handlers.get(key) ?? []), handler])
    }
    return this
  }

  // done closes what is still open under it with a done of its own, cancel with a cancel
  #closing(op, value) {
    const own = op === "cancel" && value != null ? [this.path, op, value] : [this.path, op]
    return [...this.tasks.openUnder(this.path).map((path) => (value != null ? [path, op, value] : [path, op])), own]
  }
}

// Tracks an XMLHttpRequest's upload with a task: its count is the bytes sent, its total the
// body's size, learned from the first progress event. A 2xx response finishes it; any other
// status, a network error or a timeout fails it, and an abort cancels it. Call it before
// `xhr.send`, which is when the progress events start.
//
// It only reports. Whether canceling the task - its cancel button, or the server task it is
// grafted under ending badly - stops the upload is yours to say: `abortOnCancel: true` aborts
// the request then
//
//   const xhr = new XMLHttpRequest()
//   xhr.open("PUT", url)
//   trackUpload(xhr, work.root.subtask(file.name, { unit: "bytes", cancelable: true }), { abortOnCancel: true })
//   xhr.send(file)
export function trackUpload(xhr, task, { abortOnCancel = false } = {}) {
  // All the bytes out is not the upload done, so the count reaching the total must not finish it
  task.tasks.autofinish.set(task.path.join("-"), false)
  let sent = 0
  xhr.upload.addEventListener("progress", (event) => {
    if (event.lengthComputable && task.node.total == null) task.setTotal(event.total)
    if (event.loaded > sent) task.advance(event.loaded - sent)
    sent = Math.max(sent, event.loaded)
  })
  xhr.addEventListener("load", () => {
    if (xhr.status >= 200 && xhr.status < 300) task.done()
    else task.fail(new Error(`The server answered ${xhr.status}${xhr.statusText ? ` ${xhr.statusText}` : ""}`))
  })
  xhr.addEventListener("error", () => task.fail(new Error("The upload failed - the network, or the server going away")))
  xhr.addEventListener("timeout", () => task.fail(new Error("The upload timed out")))
  xhr.addEventListener("abort", () => task.cancel("Aborted"))
  if (abortOnCancel) task.onCancel(() => xhr.abort())
  return task
}

const FIELDS = ["name", "total", "count", "percent", "weight", "expect", "indeterminate", "unit", "cancelable", "attempt", "message", "status", "error", "stale", "opened_at", "started_at", "finished_at"]

function putValue(node) {
  return Object.fromEntries(FIELDS.filter((field) => node[field] !== null && node[field] !== undefined && node[field] !== false).map((field) => [field, node[field]]))
}
