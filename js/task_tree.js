// The browser half of TaskProgress: folds batches into a tree the way TaskProgress::State
// does, and works out percents by the same rules. Framework-free - the Stimulus and React
// demos both sit on top of it.
//
//   followEventSourceAt(url, onChange)   a TaskProgress::SSE stream, drawn at most once a frame
//   followPollingAt(url, onChange)       a TaskProgress::Poll endpoint, for where SSE does not get through
//   followBatches(onChange)              the same, for batches you get some other way
//   applyBatchTo(batch, tree)            folds one batch into a tree, in place
//   tree.graft(path, localTasks)         draws tasks running in this browser under a server task

import { RenderQueue } from "./render_queue.js"
import { pathKey as key } from "./paths.js"

export { pathKey, pathFromKey } from "./paths.js"
const parentKey = (path) => key(path.slice(0, -1))

const blankNode = (path, at) => ({
  path, name: "", total: null, count: 0, percent: 0, weight: 1, expect: null, indeterminate: false, cancelable: false, attempt: null,
  unit: null, message: null, status: "pending", error: null, stale: false,
  opened_at: at, started_at: null, finished_at: null, children: []
})

// The wire format's version, as TaskProgress::Wire::VERSION - a batch from a newer writer is
// left alone rather than half understood
export const WIRE_VERSION = 1

// Siblings past FOLD_OVER are folded by TaskTree#rows, keeping FOLD_KEEP of the done and of the
// waiting ones - as TaskProgress::State#rows does
export const FOLD_OVER = 12
export const FOLD_KEEP = 3

const FINISHED = new Set(["done", "failed", "canceled"])
const ENDED_WITHOUT_DONE = new Set(["failed", "canceled"])
const ATTRIBUTES = ["name", "total", "weight", "expect", "indeterminate", "unit", "cancelable", "attempt"]
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
    this.grafts = []
    this.onLocalChange = null // set by a RenderQueue, to draw what a graft changes
  }

  // Now, by the clock of whoever wrote the tree - so an elapsed time is never off by the skew
  // between that machine and this one
  now() { return this.clock() - (this.offset ?? 0) }

  // Returns "applied", "duplicate" for a batch it already has, or "gap" when the batch does not follow the last one - the tree is then
  // stale, and stays so until a batch with prev 0 (a fresh squash) replaces it. A batch in
  // another version of the format is "unsupported", and changes nothing
  apply(batch) {
    if (batch.v !== WIRE_VERSION) return "unsupported"
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
    for (const graft of this.grafts) this.#tend(graft)
    return "applied"
  }

  // Draws tasks running in this browser - a LocalTasks - as a child of the server task at
  // `path`. Only this tree sees them. The graft is kept apart from what the server sends, so a
  // reset or a reconnect, which starts the server's tree over, puts it back; and it waits for
  // its task if that has not arrived yet. Returns a function that takes it off again.
  //
  // A server task with browser work still open under it is not complete - it reads 99% and
  // is drawn as running even once the server has called it done. A server task that fails or
  // is canceled cancels the browser work under it
  graft(path, local) {
    const graft = { anchor: [...path], local, id: local.log }
    this.grafts.push(graft)
    const unsubscribe = local.subscribe((batch) => this.#graftOps(graft, batch.ops, batch.at))
    this.#tend(graft)
    return () => {
      unsubscribe()
      this.grafts = this.grafts.filter((g) => g !== graft)
      const top = [...graft.anchor, graft.id]
      if (!this.get(top)) return
      const prefix = key(top)
      for (const k of [...this.nodes.keys()]) if (k === prefix || k.startsWith(prefix + "-")) this.nodes.delete(k)
      const anchor = this.get(graft.anchor)
      if (anchor) anchor.children = anchor.children.filter((id) => id !== graft.id)
      this.onLocalChange?.([[top, "prune"]])
    }
  }

  // Cancels a task running in this browser, by its path in this tree. Server tasks are not
  // this tree's to end - see requestCancel
  cancelLocal(path, reason) {
    const graft = this.grafts.find((g) => key([...g.anchor, g.id]) === key(path.slice(0, g.anchor.length + 1)))
    graft?.local.at(path.slice(graft.anchor.length + 1))?.cancel(reason)
  }

  // Puts a graft back if the server's tree lost it, and cancels it if its server task ended badly
  #tend(graft) {
    const anchor = this.get(graft.anchor)
    if (!anchor) return
    if (!this.get([...graft.anchor, graft.id])) {
      const squash = graft.local.squash()
      this.#graftOps(graft, squash.ops, squash.at)
    }
    if (ENDED_WITHOUT_DONE.has(anchor.status) && !graft.local.root.finished) graft.local.root.cancel(anchor.message ?? `${anchor.name} ${anchor.status}`)
  }

  #graftOps(graft, ops, at) {
    if (!this.get(graft.anchor)) return
    const top = [...graft.anchor, graft.id]
    // Lost to a reset or a prune since: the local tree already holds this change, so put it back whole
    if (!this.get(top) && !(ops[0]?.[0].length === 0 && (ops[0][1] === "open" || ops[0][1] === "put"))) {
      const squash = graft.local.squash()
      return this.#graftOps(graft, squash.ops, squash.at)
    }
    const moved = ops.map(([path, op, value]) => [[...top, ...path], op, value])
    for (const [path, op, value] of moved) this.#applyOp(path, op, value, at)
    this.onLocalChange?.(moved)
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

  // What to draw, in the order of `each` - but where a task has more than `foldOver` children, the
  // ones that are done (save the last `keep` to finish) are one row ahead of the rest, and the
  // ones still waiting (save the first `keep`) one row after them, see TaskProgress::State#rows.
  // A folded row is { fold: true, path, status, count }, its path its parent's and `~done` or
  // `~pending`, which no task id can be
  *rows(node = this.root, { foldOver = FOLD_OVER, keep = FOLD_KEEP } = {}) {
    if (!node) return
    yield node
    const kids = this.childrenOf(node)
    const options = { foldOver, keep }
    if (kids.length <= foldOver) {
      for (const kid of kids) yield* this.rows(kid, options)
      return
    }
    const done = kids.filter((kid) => this.complete(kid))
    const kept = new Set([...done].sort((a, b) => (b.finished_at ?? 0) - (a.finished_at ?? 0)).slice(0, keep))
    const pending = kids.filter((kid) => kid.status === "pending")
    const folded = new Set([...done.filter((kid) => !kept.has(kid)), ...pending.slice(keep)])
    if (done.length > kept.size) yield { fold: true, path: [...node.path, "~done"], status: "done", count: done.length - kept.size }
    for (const kid of kids) if (!folded.has(kid)) yield* this.rows(kid, options)
    if (pending.length > keep) yield { fold: true, path: [...node.path, "~pending"], status: "pending", count: pending.length - keep }
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
          if (k !== prefix && (prefix === "" || k.startsWith(prefix + "-"))) this.nodes.delete(k)
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

// Polls a TaskProgress::Poll endpoint at `url`, see followBatches - for where an EventSource does
// not get through. Every answer is the whole tree, and its ETag goes back in If-None-Match, so a
// tree that has not changed costs a 304. Polls every `interval` milliseconds; with `wait` (in
// seconds) the server holds each poll until something changes, up to that long, and the next
// one goes out at once - long polling. A poll that fails is tried again later and later, up to
// half a minute apart. It stops once the root has finished
export function followPollingAt(url, onChange, { interval = 1000, wait = 0, ...options } = {}) {
  const following = followBatches(onChange, options)
  const { tree } = following
  const target = wait ? `${url}${url.includes("?") ? "&" : "?"}wait=${wait}` : url
  let etag = null
  let stopped = false
  let timer = null
  let controller = null
  let delay = interval
  const poll = async () => {
    controller = new AbortController()
    try {
      const response = await fetch(target, { headers: etag ? { "if-none-match": etag } : {}, cache: "no-store", signal: controller.signal })
      if (response.status === 200) {
        const batch = await response.json()
        etag = response.headers.get("etag")
        following.push(batch)
      } else if (response.status !== 304) {
        throw new Error(`Polling ${url} got a ${response.status}`)
      }
      delay = interval
    } catch {
      if (stopped) return
      delay = Math.min(Math.max(delay, interval) * 2, 30000)
    }
    if (stopped || (tree.root && FINISHED.has(tree.root.status))) return
    timer = setTimeout(poll, wait && delay === interval ? 0 : delay)
  }
  poll()
  return {
    tree,
    close: () => {
      stopped = true
      clearTimeout(timer)
      controller?.abort()
      following.close()
    }
  }
}

// Asks the server to cancel a task, by creating a cancellation: posts JSON with the task's path
// (its pathKey) and the token the server issued for this tree. The server decides -
// a task is only ever ended by its own tree - so nothing changes here until the `cancel` comes
// back down the stream. A request that comes too late is not an error: the server answers it as
// "moot", and the row has already finished anyway
//
// On a Rails page it sends the page's CSRF token along, so `protect_from_forgery` lets it through
export function requestCancel(url, path, { token } = {}) {
  const csrf = globalThis.document?.querySelector('meta[name="csrf-token"]')?.content
  return fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", ...(csrf ? { "x-csrf-token": csrf } : {}) },
    body: JSON.stringify({ path: key(path), token })
  })
}

export function humanBytes(n) {
  const scale = [["TB", 1024 ** 4], ["GB", 1024 ** 3], ["MB", 1024 ** 2], ["KB", 1024]]
  const found = scale.find(([, size]) => n >= size)
  if (!found) return `${n} bytes`
  const value = Math.round((n / found[1]) * 10) / 10
  return `${Number.isInteger(value) ? value : value.toFixed(1)} ${found[0]}`
}
