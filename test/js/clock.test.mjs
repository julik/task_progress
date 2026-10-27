// node --test examples/web/test/
import { test } from "node:test"
import assert from "node:assert/strict"
import { TaskTree } from "../../js/task_tree.js"
import { rowView } from "../../js/row_view.js"

const batch = (seq, at, ops, prev = seq - 1) => ({ log: "w", prev, seq, at, ops })

test("elapsed time is measured on the writer's clock, whatever ours says", () => {
  let local = 1_000_000 // days ahead of the writer
  const tree = new TaskTree({ clock: () => local })
  tree.apply(batch(1, 5_000, [[[], "open", { name: "root" }], [[0], "open", { name: "wait", indeterminate: true }]], 0))
  tree.apply(batch(2, 5_010, [[[0], "note", "started"]]))
  local += 4
  assert.equal(rowView(tree, tree.get([0])).measure, "4.0s")
})

test("the batch with the least time in transit sets the offset", () => {
  let local = 100
  const tree = new TaskTree({ clock: () => local })
  tree.apply(batch(1, 90, [[[], "open", { name: "root" }]], 0))
  local = 103
  tree.apply(batch(2, 101, [[[], "note", "x"]]))
  assert.equal(tree.offset, 2)
  local = 120
  tree.apply(batch(3, 101, [[[], "note", "held up in transit"]]))
  assert.equal(tree.offset, 2)
  assert.equal(tree.now(), 118)
})

test("a finished task shows its own duration", () => {
  const tree = new TaskTree({ clock: () => 0 })
  tree.apply(batch(1, 50, [[[], "open", { name: "root", indeterminate: true }], [[], "note", "go"]], 0))
  tree.apply(batch(2, 57.5, [[[], "done"]]))
  const root = tree.get([])
  assert.equal(root.finished_at - root.started_at, 7.5)
})

test("a counted task shows its rate and the time left, on the writer's clock", () => {
  let local = 1_000_000
  const tree = new TaskTree({ clock: () => local })
  tree.apply(batch(1, 5_000, [[[], "open", { name: "root" }], [["a0b1"], "open", { name: "rows", total: 100 }]], 0))
  tree.apply(batch(2, 5_000, [[["a0b1"], "add", 1]]))
  tree.apply(batch(3, 5_010, [[["a0b1"], "add", 19], [["a0b1"], "say", "a line for the log, not the tree"]]))
  local += 10
  assert.equal(rowView(tree, tree.get(["a0b1"])).message, "1.0/s, 1m20s left") // 20 rows in the 20s since it started
})
