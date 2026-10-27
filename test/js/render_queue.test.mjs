// node --test examples/web/test/
import { test } from "node:test"
import assert from "node:assert/strict"
import { TaskTree, batchFeed, pathKey, pathFromKey } from "../../js/task_tree.js"
import { RenderQueue } from "../../js/render_queue.js"

const batch = (seq, ops, prev = seq - 1) => ({ v: 1, log: "w", prev, seq, at: seq, ops })

// Frames come only when the test says so
function setup() {
  const frames = []
  const renders = []
  const queue = new RenderQueue(new TaskTree({ clock: () => 0 }), (tree, changes) => renders.push(changes), { schedule: (fn) => frames.push(fn) })
  const frame = () => frames.splice(0).forEach((fn) => fn())
  return { queue, renders, frames, frame }
}

const opening = batch(1, [[[], "open", { name: "root" }], [[0], "open", { name: "a", total: 1000 }], [[1], "open", { name: "b" }]], 0)

test("many batches in one frame are one render, and every one of them is folded", () => {
  const { queue, renders, frames, frame } = setup()
  queue.apply(opening)
  for (let seq = 2; seq <= 501; seq++) queue.apply(batch(seq, [[[0], "add", 1]]))
  assert.equal(frames.length, 1)
  assert.equal(renders.length, 0)
  frame()
  assert.equal(renders.length, 1)
  assert.equal(renders[0].batches, 501)
  assert.equal(queue.tree.seq, 501)
  assert.equal(queue.tree.get([0]).count, 500)
  frame()
  assert.equal(renders.length, 1, "nothing new, nothing drawn")
})

test("the touched set has the changed rows and the rows above them, and no others", () => {
  const { queue, renders, frame } = setup()
  queue.apply(opening)
  frame()
  assert.equal(renders[0].structure, true)
  queue.apply(batch(2, [[[0], "add", 1]]))
  queue.apply(batch(3, [[[0], "note", "x"]]))
  frame()
  assert.deepEqual([...renders[1].touched].sort(), ["", "0"])
  assert.equal(renders[1].structure, false)
})

test("done, fail and say inside a collapsed frame are all reported, in order", () => {
  const { queue, renders, frame } = setup()
  queue.apply(opening)
  queue.apply(batch(2, [[[0], "say", "first line"], [[0], "done"]]))
  queue.apply(batch(3, [[[1], "fail", { class: "RuntimeError", message: "boom" }]]))
  // A later state hides both: a put brings the failed row back as pending
  queue.apply(batch(4, [[[1], "put", { name: "b", status: "pending" }], [[], "say", "second line"]]))
  frame()
  assert.equal(queue.tree.get([1]).status, "pending")
  const events = renders[0].events.map(({ op, path, value }) => [op, path, value])
  assert.deepEqual(events, [
    ["reset", undefined, undefined],
    ["say", [0], "first line"],
    ["done", [0], null],
    ["fail", [1], { class: "RuntimeError", message: "boom" }],
    ["say", [], "second line"]
  ])
})

test("a reset and a gap are reported, and the ops of a batch that did not apply are not", () => {
  const { queue, renders, frame } = setup()
  queue.apply(opening)
  frame()
  assert.equal(queue.apply(batch(5, [[[0], "done"]], 4)), "gap")
  frame()
  assert.deepEqual(renders[1].events.map((e) => e.op), ["gap"])
  assert.equal(renders[1].touched.size, 0)
  queue.apply(batch(9, [[[], "open", { name: "root" }]], 0))
  frame()
  assert.deepEqual(renders[2].events.map((e) => e.op), ["reset"])
  assert.equal(renders[2].structure, true)
  assert.equal(queue.tree.get([0]), undefined)
})

test("a closed queue draws nothing more", () => {
  const { queue, renders, frame } = setup()
  queue.apply(opening)
  queue.close()
  frame()
  assert.equal(renders.length, 0)
  assert.equal(queue.tree.seq, 1)
})

test("apply folds a batch into the tree in place", () => {
  const tree = new TaskTree()
  assert.equal(tree.apply({ v: 1, log: "w", prev: 0, seq: 1, at: 1, ops: [[[], "open", { name: "root" }], [["a"], "open", { name: "a" }]] }), "applied")
  assert.equal(tree.apply({ v: 1, log: "w", prev: 1, seq: 2, at: 2, ops: [[["a"], "add", 3]] }), "applied")
  assert.equal(tree.get(["a"]).count, 3)
  assert.equal(tree.apply({ v: 1, log: "w", prev: 1, seq: 2, at: 2, ops: [[["a"], "add", 3]] }), "duplicate")
  assert.equal(tree.apply({ v: 1, log: "w", prev: 7, seq: 8, at: 3, ops: [] }), "gap")
  assert.equal(tree.apply({ v: 2, log: "w", prev: 0, seq: 9, at: 4, ops: [] }), "unsupported", "a newer writer is left alone")
  assert.equal(tree.stale, true)
})

test("batchFeed folds what is pushed and draws once a frame", () => {
  const frames = []
  let pending = null
  const following = batchFeed((tree, changes) => frames.push([tree.get(["a"]).count, changes.batches]), { schedule: (fn) => (pending = fn) })
  following.push({ v: 1, log: "w", prev: 0, seq: 1, at: 1, ops: [[[], "open", { name: "root" }], [["a"], "open", { name: "a" }]] })
  for (let seq = 2; seq <= 10; seq++) assert.equal(following.push({ v: 1, log: "w", prev: seq - 1, seq, at: seq, ops: [[["a"], "add", 1]] }), "applied")
  assert.equal(following.push({ v: 1, log: "w", prev: 40, seq: 41, at: 41, ops: [] }), "gap")
  pending()
  assert.deepEqual(frames, [[9, 11]])
})

test("a path's key joins its ids with a dash, and splits back", () => {
  assert.equal(pathKey(["x3k0", "00af"]), "x3k0-00af")
  assert.equal(pathKey([]), "")
  assert.deepEqual(pathFromKey("x3k0-00af"), ["x3k0", "00af"])
  assert.deepEqual(pathFromKey(""), [])
})
