// The browser half of TaskProgress: folds batches into a tree the way TaskProgress::State
// does, and works out percents by the same rules. Framework-free - the Stimulus and React
// demos both sit on top of it.
//
//   followEventSourceAt(url, onChange)   a TaskProgress::SSE stream, drawn at most once a frame
//   followBatches(onChange)              the same, for batches you get some other way
//   applyBatchTo(batch, tree)            folds one batch into a tree, in place

import { RenderQueue } from "./render_queue.js"

const key = (path) => path.join("/")
const parentKey = (path) => key(path.slice(0, -1))

const blankNode = (path, at) => ({
  path, name: "", total: null, count: 0, percent: 0, weight: 1, expect: null, indeterminate: false, cancelable: false,
  unit: null, message: null, status: "pending", error: null, stale: false,
  opened_at: at, started_at: null, finished_at: null, children: []
})

const FINISHED = new Set(["done", "failed", "canceled"])
const ENDED_WITHOUT_DONE = new Set(["failed", "canceled"])
const ATTRIBUTES = ["name", "total", "weight", "expect", "indeterminate", "unit", "cancelable"]
const FIELDS = [...ATTRIBUTES, "count", "percent", "message", "status", "error", "stale", "opened_at", "started_at", "finished_at"]

export class TaskTree {
  // `clock` gives seconds since the epoch, and only matters for elapsed times
  constructor({ clock = () => Date.now() / 1000 } = {}) {
    this.nodes = new Map()
    this.log = null
    this.seq = null
    this.stale = false
    this.clock = clock
    this.offset = null
  }

  // Now, by the clock of whoever wrote the tree - so an elapsed time is never off by the skew
  // between that machine and this one
  now() { return this.clock() - (this.offset ?? 0) }

  // Returns "applied", "duplicate" for a batch it already has, or "gap" when the batch does not follow the last one - the tree is then
  // stale, and stays so until a batch with prev 0 (a fresh squash) replaces it
  apply(batch) {
    if (batch.prev === 0) {
      this.nodes = new Map()
    } else if (batch.log === this.log && batch.seq <= this.seq) {
      return "duplicate"
    } else if (batch.log !== this.log || batch.prev !== this.seq) {
      this.stale = true
      return "gap"
    }
    for (const [path, op, value] of batch.ops) this.#applyOp(path, op, value, batch.at)
    this.#measureOffset(batch)
    this.log = batch.log
    this.seq = batch.seq
    this.stale = false
    return "applied"
  }

  get(path) { return this.nodes.get(key(path)) }

  get root() { return this.nodes.get("") }

  childrenOf(node) { return node.children.map((id) => this.nodes.get(key([...node.path, id]))) }

  // Pre-order, children by position
  *each(node = this.root) {
    if (!node) return
    yield node
    for (const child of this.childrenOf(node)) yield* this.each(child)
  }

  // Done, and everything under it ended - see TaskProgress::State#complete?
  complete(node) {
    if (node?.status !== "done") return false
    return this.childrenOf(node).every((child) => ENDED_WITHOUT_DONE.has(child.status) || this.complete(child))
  }

  fraction(node) {
    if (!node) return 0
    if (node.status === "done") return 1
    const missing = this.#missing(node)
    if (node.children.length > 0 || missing > 0) {
      let weights = missing
      let sum = 0
      for (const child of this.childrenOf(node)) {
        weights += child.weight
        sum += child.weight * this.fraction(child)
      }
      return weights === 0 ? 0 : sum / weights
    }
    if (node.total != null) return node.total === 0 ? 0 : Math.min(Math.max(node.count / node.total, 0), 1)
    if (node.indeterminate) return 0
    return node.percent / 100
  }

  // A whole percent that reaches 100 only once everything under the node is done. Math.round
  // rounds .5 up like Ruby's round does for the positive numbers we have here
  percentOf(node) {
    if (this.complete(node)) return 100
    return Math.min(Math.round(this.fraction(node) * 100), 99)
  }

  // Each batch says what the writer's clock read when it committed. The smallest gap to ours has
  // the least time in transit in it, so that is the one kept
  #measureOffset(batch) {
    if (!batch.at) return
    const offset = this.clock() - batch.at
    this.offset = batch.log !== this.log || this.offset === null ? offset : Math.min(this.offset, offset)
  }

  #missing(node) { return Math.max((node.expect ?? 0) - node.children.length, 0) }

  #start(path, at) {
    for (let length = path.length; length >= 0; length--) {
      const node = this.nodes.get(key(path.slice(0, length)))
      if (node.status === "pending") node.status = "active"
      node.started_at ??= at
    }
  }

  #adopt(path) {
    if (path.length === 0) return
    const parent = this.nodes.get(parentKey(path))
    const id = path[path.length - 1]
    if (!parent.children.includes(id)) parent.children.push(id)
  }

  #applyOp(path, op, value, at) {
    const node = this.nodes.get(key(path))
    switch (op) {
      case "open": {
        const fresh = blankNode(path, at)
        for (const field of ATTRIBUTES) if (value[field] !== undefined) fresh[field] = value[field]
        this.nodes.set(key(path), fresh)
        this.#adopt(path)
        break
      }
      case "meta":
        for (const field of [...ATTRIBUTES, "stale"]) if (value[field] !== undefined) node[field] = value[field]
        break
      case "set": this.#start(path, at); node.percent = value; break
      case "add": this.#start(path, at); node.count = Math.max(node.count + value, 0); break
      case "note": this.#start(path, at); node.message = value ?? null; break
      case "say": break // a line for a log pane - nothing in the tree changes
      case "done":
      case "fail":
        this.#start(path, at)
        node.finished_at = at
        node.status = op === "done" ? "done" : "failed"
        if (op === "fail") node.error = value
        break
      case "cancel": // calling off what never began does not begin it
        node.finished_at = at
        node.status = "canceled"
        if (value) node.message = value
        break
      case "prune": {
        if (!node) break
        const prefix = key(path)
        for (const k of [...this.nodes.keys()]) {
          if (k !== prefix && (prefix === "" || k.startsWith(prefix + "/"))) this.nodes.delete(k)
        }
        node.children = []
        break
      }
      case "put": {
        const fresh = blankNode(path, at)
        for (const field of FIELDS) if (value[field] !== undefined) fresh[field] = value[field]
        fresh.children = node ? node.children : []
        this.nodes.set(key(path), fresh)
        if (!node) this.#adopt(path)
        break
      }
    }
  }
}

// Folds the batch into the tree, in place. Returns "applied", "duplicate" or "gap", see TaskTree#apply
export function applyBatchTo(batch, tree) { return tree.apply(batch) }

// Folds batches pushed into it from anywhere - a WebSocket, ActionCable, a poller - and calls
// onChange(tree, changes) at most once a frame with what they changed, see render_queue.js.
// `push` returns what the tree made of the batch: on a "gap" it is for the caller to start
// over, by fetching a fresh squash (a batch with prev 0)
export function followBatches(onChange, { schedule, clock } = {}) {
  const tree = new TaskTree(clock ? { clock } : {})
  const queue = new RenderQueue(tree, onChange, { schedule })
  return { tree, push: (batch) => queue.apply(batch), close: () => queue.close() }
}

// Follows a TaskProgress::SSE stream at `url`, see followBatches. On a gap it reconnects, and
// the server starts it over from a fresh squash. It stops once the root has finished
export function followEventSourceAt(url, onChange, options = {}) {
  const following = followBatches(onChange, options)
  const { tree } = following
  let source
  const connect = () => {
    source = new EventSource(url)
    source.addEventListener("batch", (event) => {
      if (following.push(JSON.parse(event.data)) === "gap") {
        source.close()
        connect()
      }
      if (tree.root && FINISHED.has(tree.root.status)) source.close()
    })
  }
  connect()
  return { tree, close: () => { source.close(); following.close() } }
}

// Asks the server to call a task off. The server decides - a task is only ever ended by its own
// tree - so nothing changes here until the `cancel` comes back down the stream. Posts the task's
// path as `path`, its ids joined with "/" (see TaskProgress#find)
export function requestCancel(url, path) {
  return fetch(url, { method: "POST", body: new URLSearchParams({ path: path.join("/") }) })
}

export function humanBytes(n) {
  const scale = [["TB", 1024 ** 4], ["GB", 1024 ** 3], ["MB", 1024 ** 2], ["KB", 1024]]
  const found = scale.find(([, size]) => n >= size)
  if (!found) return `${n} bytes`
  const value = Math.round((n / found[1]) * 10) / 10
  return `${Number.isInteger(value) ? value : value.toFixed(1)} ${found[0]}`
}
