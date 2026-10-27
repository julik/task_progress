import { test } from "node:test"
import assert from "node:assert/strict"
import { TaskTree, followPollingAt } from "../../js/task_tree.js"
import { LocalTasks } from "../../js/local_tasks.js"

const batch = (seq, ops, prev = seq - 1, at = seq) => ({ v: 1, log: "w", prev, seq, at, ops })

test("a cancel with an empty reason clears the message, as the Ruby side does", () => {
  const tree = new TaskTree()
  tree.apply(batch(1, [[[], "open", { name: "Job" }], [[], "note", "Reading"]], 0))
  tree.apply(batch(2, [[[], "cancel", ""]]))
  assert.equal(tree.root.message, "")
})

test("work grafted from this browser is timed on the server's clock", () => {
  const now = 1000
  const tree = new TaskTree({ clock: () => now })
  // The server is 300 seconds ahead of this browser
  tree.apply(batch(1, [[[], "open", { name: "Job" }]], 0, now + 300))
  const work = new LocalTasks("Hash", { clock: () => now })
  tree.graft([], work)
  work.root.note("started")
  const grafted = tree.get([work.log])
  assert.ok(Math.abs(grafted.started_at - (now + 300)) < 1, `started on the server's clock, got ${grafted.started_at}`)
})

test("polling stops on a tree that is empty - its task was pruned", async () => {
  const asked = []
  globalThis.fetch = async (url) => {
    asked.push(url)
    return { status: 200, headers: { get: () => '"e"' }, json: async () => batch(1, [], 0) }
  }
  const following = followPollingAt("/poll", () => {}, { poll: 0.001, schedule: (fn) => fn() })
  await new Promise((resolve) => setTimeout(resolve, 30))
  following.close()
  assert.equal(asked.length, 1)
})

test("long polls are spaced, however busy the tree", async () => {
  const asked = []
  let seq = 0
  globalThis.fetch = async (url) => {
    asked.push(url)
    seq += 1
    return { status: 200, headers: { get: () => `"${seq}"` }, json: async () => batch(seq, [[[], "put", { name: "Job", status: "active", note: seq }]], 0) }
  }
  const following = followPollingAt("/poll", () => {}, { wait: 25, schedule: (fn) => fn() })
  await new Promise((resolve) => setTimeout(resolve, 600))
  following.close()
  assert.ok(asked.length <= 4, `asked ${asked.length} times in 600ms`)
})
