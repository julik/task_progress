import { test } from "node:test"
import assert from "node:assert/strict"
import { followProgress } from "../../js/task_tree.js"

const batch = (seq, ops, prev = seq - 1) => ({ v: 1, log: "w", prev, seq, at: seq, ops })

// An EventSource that does what the test tells it to
class FakeEventSource {
  static last = null
  constructor(url) { this.url = url; this.listeners = {}; this.closed = false; FakeEventSource.last = this }
  addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn) }
  emit(name, data) { for (const fn of this.listeners[name] || []) fn(data === undefined ? {} : { data: JSON.stringify(data) }) }
  close() { this.closed = true }
}
globalThis.EventSource = FakeEventSource

const progress = {
  events: "/task_progress/trees/t0k/events",
  poll: "/task_progress/trees/t0k/poll",
  cancel: "/task_progress/trees/t0k/cancellations",
  snapshot: batch(3, [[[], "put", { name: "Importing", status: "pending" }]], 0)
}

test("the snapshot is drawn before anything comes in", () => {
  const drawn = []
  const following = followProgress(progress, (tree) => drawn.push(tree.root.name), { schedule: (fn) => fn() })
  assert.deepEqual(drawn, ["Importing"])
  assert.equal(FakeEventSource.last.url, progress.events)
  FakeEventSource.last.emit("batch", batch(1, [[[], "open", { name: "Importing" }], [[], "note", "working"]], 0))
  assert.equal(following.tree.root.message, "working", "and the stream takes over from it")
  following.close()
})

test("a stream that cannot be reached falls back to polling", async () => {
  const asked = []
  globalThis.fetch = async (url) => {
    asked.push(url)
    return { status: 200, headers: { get: () => '"a"' }, json: async () => batch(1, [[[], "put", { name: "Importing", status: "done" }]], 0) }
  }
  const following = followProgress(progress, () => {}, { schedule: (fn) => fn(), poll: 0.01 })
  const stream = FakeEventSource.last
  stream.emit("error")
  await new Promise((resolve) => setTimeout(resolve, 30))
  assert.ok(stream.closed, "the stream is given up")
  assert.equal(asked[0], progress.poll)
  assert.equal(following.tree.root.status, "done", "and the tree is the polled one now")
  following.close()
})

test("a stream that never says anything falls back too - a proxy that buffers", async () => {
  globalThis.fetch = async () => ({ status: 304, headers: { get: () => null } })
  const following = followProgress(progress, () => {}, { schedule: (fn) => fn(), unreachableAfter: 0.02, poll: 1 })
  const stream = FakeEventSource.last
  await new Promise((resolve) => setTimeout(resolve, 50))
  assert.ok(stream.closed)
  following.close()
})
