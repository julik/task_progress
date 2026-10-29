import { test } from "node:test"
import assert from "node:assert/strict"
import { TaskTree, followLocal } from "../../js/task_tree.js"
import { LocalTasks, trackUpload } from "../../js/local_tasks.js"
import { rowView } from "../../js/row_view.js"

const server = (seq, ops, prev = seq - 1) => ({ v: 1, log: "srv", prev, seq, at: seq, ops })
const serverTree = () => {
  const tree = new TaskTree()
  tree.apply(server(1, [[[], "open", { name: "Job" }], [["up00"], "open", { name: "Upload" }], [["pub0"], "open", { name: "Publish" }]], 0))
  return tree
}

test("local tasks follow the server's rules", () => {
  const work = new LocalTasks("Hash files")
  const a = work.root.subtask("a.bin", { total: 2 })
  const b = work.root.subtask("b.bin")
  a.advance(2)
  assert.equal(a.status, "done", "a counted task is done at its total")
  b.note("started")
  work.root.done()
  assert.equal(b.status, "done", "done closes what is still open under it")
  assert.ok(work.root.subtask("late") === null, "nothing opens under a finished task")
  assert.ok(a.path[0].startsWith("_"), "ids a server never makes")
})

test("cancel cancels what is open under it, and calls onCancel with the reason", () => {
  const work = new LocalTasks("Hash files")
  const a = work.root.subtask("a.bin", { total: 10 })
  const reasons = []
  a.onCancel((reason) => reasons.push(reason))
  a.advance(3)
  work.root.cancel("Not needed")
  assert.equal(a.status, "canceled")
  assert.deepEqual(reasons, ["Not needed"])
  a.advance(1)
  assert.equal(a.node.count, 3, "a canceled task takes no more")
  a.onCancel((reason) => reasons.push(`late: ${reason}`))
  assert.deepEqual(reasons, ["Not needed", "late: Not needed"])
})

test("a graft is drawn under its server task, and counts towards it", () => {
  const tree = serverTree()
  const work = new LocalTasks("Hash files")
  tree.graft(["up00"], work)
  const file = work.root.subtask("a.bin", { total: 4 })
  file.advance(2)
  const upload = tree.get(["up00"])
  assert.equal(upload.children.length, 1)
  const row = rowView(tree, tree.get([...file.path.slice(0, 0), "up00", work.log, ...file.path]))
  assert.equal(row.local, true)
  assert.equal(tree.percentOf(upload), 50)
})

test("a server task done with browser work still open under it is not through", () => {
  const tree = serverTree()
  const work = new LocalTasks("Hash files")
  tree.graft(["up00"], work)
  const file = work.root.subtask("a.bin", { total: 4 })
  tree.apply(server(2, [[["up00"], "done"], [["pub0"], "done"], [[], "done"]]))
  const upload = tree.get(["up00"])
  assert.equal(tree.complete(upload), false)
  assert.equal(tree.percentOf(tree.root), 99, "the job is not at 100% while the browser works")
  assert.equal(rowView(tree, upload).status, "active", "and is drawn as running")
  file.advance(4)
  work.root.done()
  assert.equal(tree.percentOf(tree.root), 100)
  assert.equal(rowView(tree, upload).status, "done")
})

test("a graft survives the server starting over, and waits for its task", () => {
  const tree = new TaskTree()
  const work = new LocalTasks("Hash files")
  tree.graft(["up00"], work)
  const file = work.root.subtask("a.bin", { total: 4 })
  file.advance(1)
  assert.equal(tree.root, undefined, "nothing to graft to yet")
  tree.apply(server(1, [[[], "open", { name: "Job" }], [["up00"], "open", { name: "Upload" }]], 0))
  assert.equal(tree.get(["up00", work.log, ...file.path]).count, 1, "attached once its task arrived")
  tree.apply(server(5, [[[], "put", { name: "Job", status: "active" }], [["up00"], "put", { name: "Upload", status: "active" }]], 0))
  assert.equal(tree.get(["up00", work.log, ...file.path]).count, 1, "back after a reset")
  file.advance(1)
  assert.equal(tree.get(["up00", work.log, ...file.path]).count, 2)
})

test("a server task that fails or is canceled cancels the browser work under it", () => {
  const tree = serverTree()
  const work = new LocalTasks("Hash files")
  tree.graft(["up00"], work)
  const file = work.root.subtask("a.bin", { total: 4 })
  const reasons = []
  file.onCancel((reason) => reasons.push(reason))
  tree.apply(server(2, [[["up00"], "cancel", "Canceled from the browser"]]))
  assert.equal(file.status, "canceled")
  assert.deepEqual(reasons, ["Canceled from the browser"])
})

test("a local task is canceled from the tree, and an ungraft takes it off", () => {
  const tree = serverTree()
  const work = new LocalTasks("Hash files", { cancelable: true })
  const ungraft = tree.graft(["up00"], work)
  const file = work.root.subtask("a.bin", { total: 4, cancelable: true })
  tree.cancelLocal(["up00", work.log, ...file.path], "Canceled in this browser")
  assert.equal(file.status, "canceled")
  ungraft()
  assert.deepEqual(tree.get(["up00"]).children, [])
  assert.equal(tree.get(["up00", work.log]), undefined)
})

// Enough of an XMLHttpRequest for trackUpload: it only listens, and aborts
class FakeXHR extends EventTarget {
  constructor() { super(); this.upload = new EventTarget(); this.status = 0; this.aborted = false }
  progress(loaded, total) { this.upload.dispatchEvent(Object.assign(new Event("progress"), { loaded, total, lengthComputable: true })) }
  finish(status) { this.status = status; this.dispatchEvent(new Event("load")) }
  abort() { this.aborted = true; this.dispatchEvent(new Event("abort")) }
}

test("trackUpload follows an upload's progress, and finishes when the server answers", () => {
  const work = new LocalTasks("Upload")
  const xhr = new FakeXHR()
  const file = trackUpload(xhr, work.root.subtask("video.mp4", { unit: "bytes", cancelable: true }))
  xhr.progress(0, 1000)
  xhr.progress(400, 1000)
  assert.deepEqual([file.node.count, file.node.total, file.status], [400, 1000, "active"])
  xhr.progress(1000, 1000)
  assert.equal(file.status, "active", "the body is out, but the server has not answered")
  xhr.finish(201)
  assert.equal(file.status, "done")
})

test("trackUpload fails on an error answer, and a cancel aborts the request only when asked to", () => {
  const work = new LocalTasks("Upload")
  const failing = new FakeXHR()
  const a = trackUpload(failing, work.root.subtask("a.bin", { unit: "bytes" }))
  failing.progress(10, 10)
  failing.finish(413)
  assert.equal(a.status, "failed")
  assert.equal(a.node.error.message, "The server answered 413")

  const reporting = new FakeXHR()
  const b = trackUpload(reporting, work.root.subtask("b.bin", { unit: "bytes", cancelable: true }))
  b.cancel("Canceled in this browser")
  assert.equal(reporting.aborted, false, "by default it only reports - the upload is not its to stop")
  reporting.finish(200)
  assert.equal(b.status, "canceled", "and an upload that finishes anyway changes nothing")

  const aborting = new FakeXHR()
  const c = trackUpload(aborting, work.root.subtask("c.bin", { unit: "bytes", cancelable: true }), { abortOnCancel: true })
  aborting.progress(5, 100)
  c.cancel("Canceled in this browser")
  assert.equal(aborting.aborted, true, "asked to, a cancel aborts the request")
  assert.equal(c.node.message, "Canceled in this browser", "and the abort it caused does not overwrite the reason")
})

test("a task's signal aborts with the reason once it is canceled - and only what it is handed to", () => {
  const work = new LocalTasks("Fetch")
  const task = work.root.subtask("report.csv", { cancelable: true })
  const signal = task.signal
  assert.equal(signal, task.signal, "the same signal every time")
  assert.equal(signal.aborted, false)
  work.root.cancel("Not needed")
  assert.equal(signal.aborted, true)
  assert.equal(signal.reason, "Not needed")
  const late = work.root.signal
  assert.equal(late.aborted, true, "asked for after the cancel, it is aborted already")
})

test("whenFinished settles with how the task ended", async () => {
  const work = new LocalTasks("Upload")
  const a = work.root.subtask("a")
  const b = work.root.subtask("b")
  const both = Promise.all([a.whenFinished(), b.whenFinished()])
  a.done()
  b.fail(new Error("nope"))
  assert.deepEqual(await both, ["done", "failed"])
  assert.equal(await a.whenFinished(), "done", "and at once, once it has")
})

test("followLocal draws tasks from this browser on their own, and cancels them here", () => {
  const uploads = new LocalTasks("Uploads", { cancelable: true })
  const early = uploads.root.subtask("a.bin", { unit: "bytes", cancelable: true })
  const drawn = []
  const following = followLocal(uploads, (tree) => drawn.push([...tree.rows()].map((node) => rowView(tree, node))), { schedule: (fn) => fn() })
  assert.deepEqual([...following.tree.rows()].map((node) => node.name), ["Uploads", "a.bin"], "what was there before is drawn at once")
  const xhr = new FakeXHR()
  trackUpload(xhr, uploads.root.subtask("b.bin", { unit: "bytes", cancelable: true }), { abortOnCancel: true })
  xhr.progress(50, 100)
  const rows = drawn.at(-1)
  assert.deepEqual(rows.map((row) => [row.name, row.measure]), [["Uploads", "25%"], ["a.bin", "0%"], ["b.bin", "50 bytes / 100 bytes"]])
  assert.ok(rows.every((row) => row.local), "the root too - there is no server to ask")
  following.tree.cancelLocal(rows[2].path, "Canceled in this browser")
  assert.equal(xhr.aborted, true)
  following.tree.cancelLocal([], "Canceled in this browser")
  assert.equal(early.status, "canceled")
  assert.equal(following.tree.root.status, "canceled")
  following.close()
  const count = drawn.length
  uploads.root.subtask("c.bin")
  assert.equal(drawn.length, count, "closed, it stops drawing")
})
