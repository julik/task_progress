// Folds NDJSON batches from a file with the browser client and prints every node's percent,
// for test/js_parity_test.rb to hold against the Ruby side
import { readFileSync } from "node:fs"
import { TaskTree } from "../../js/task_tree.js"

const tree = new TaskTree()
for (const line of readFileSync(process.argv[2], "utf8").split("\n")) {
  if (line) tree.apply(JSON.parse(line))
}
const rows = [...tree.each()].map((node) => [node.path, node.name, node.status, tree.percentOf(node)])
process.stdout.write(JSON.stringify({ seq: tree.seq, rows }))
