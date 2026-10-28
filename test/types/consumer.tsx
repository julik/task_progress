import { followProgress, TaskTree, type Progress, type Batch } from "task_progress"
import { useTaskTree, TaskTreeView, createTaskTreeRoot, type Progress as PageProgress, type RowView } from "task_progress/react"
import TaskTreeController from "task_progress/stimulus"
import { LocalTasks, trackUpload } from "task_progress/local_tasks"
import { rowView } from "task_progress/row_view"
import "task_progress/clock"

const progress: Progress = { events: "/e", poll: "/p", cancel: "/c" }
const following = followProgress(progress, (tree, changes) => { console.log(tree.root?.name, changes.structure) }, { transport: "auto", poll: 1 })
following.close()
const tree = new TaskTree()
const outcome: "applied" | "duplicate" | "gap" | "unsupported" = tree.apply({ v: 1, log: "x", prev: 0, seq: 1, at: 0, ops: [[[], "open", { name: "x" }]] } satisfies Batch)
for (const node of tree.rows()) rowView(tree, node).percent.toFixed()
const work = new LocalTasks("Hash", { cancelable: true })
const file = work.root.subtask("a.bin", { unit: "bytes" })
if (file) trackUpload(new XMLHttpRequest(), file, { abortOnCancel: true }).advance(10)

export function Page({ progress }: { progress: Progress }) {
  const { rows, cancel } = useTaskTree(progress, { onComplete: () => console.log("done") })
  return <div className="tree">
    <TaskTreeView progress={progress} onComplete={() => {}} />
    {rows.map((row) => <button key={row.key} onClick={() => cancel(row)}>{row.name}</button>)}
  </div>
}
createTaskTreeRoot(document.body).render({ progress })
class X extends TaskTreeController {}
const fromReact: PageProgress = progress
const row: RowView | undefined = undefined
console.log(outcome, X, fromReact, row)
