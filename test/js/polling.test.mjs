import { test } from "node:test"
import assert from "node:assert/strict"
import { followPollingAt } from "../../js/task_tree.js"

const squash = (seq, ops) => ({ v: 1, log: "w", prev: 0, seq, at: seq, ops })
const reply = (status, body, etag) => ({ status, headers: { get: () => etag }, json: async () => body })

test("polls with the ETag it was given, and stops once the root has finished", async () => {
  const asked = []
  const answers = [
    reply(200, squash(1, [[[], "open", { name: "root" }]]), '"a"'),
    reply(304),
    reply(200, squash(2, [[[], "put", { name: "root", status: "done" }]]), '"b"')
  ]
  globalThis.fetch = async (url, init) => { asked.push([url, init.headers["if-none-match"]]); return answers.shift() }
  const drawn = []
  const following = followPollingAt("/jobs/1/poll", (tree) => drawn.push(tree.root.status), { interval: 1, schedule: (fn) => fn() })
  await new Promise((resolve) => setTimeout(resolve, 50))
  assert.deepEqual(asked, [["/jobs/1/poll", undefined], ["/jobs/1/poll", '"a"'], ["/jobs/1/poll", '"a"']])
  assert.equal(following.tree.root.status, "done")
  assert.equal(answers.length, 0, "no poll after the root finished")
  following.close()
})

test("long polls ask the server to wait, and back off when it fails", async () => {
  const asked = []
  globalThis.fetch = async (url) => { asked.push(url); throw new Error("offline") }
  const following = followPollingAt("/poll?job=1", () => {}, { interval: 5, wait: 25 })
  await new Promise((resolve) => setTimeout(resolve, 40))
  following.close()
  assert.equal(asked[0], "/poll?job=1&wait=25")
  assert.ok(asked.length <= 3, `backed off, asked ${asked.length} times`)
})
