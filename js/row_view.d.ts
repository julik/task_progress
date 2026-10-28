import type { TaskTree, Node, Fold, Status, Path } from "./task_tree.js"

/** What one row shows */
export interface RowView {
  key: string
  path: Path
  depth: number
  name: string
  status: Status
  stale: boolean
  /** Runs in this browser, see LocalTasks */
  local: boolean
  cancelable: boolean
  /** Siblings folded into this one row */
  folded?: boolean
  percent: number
  indeterminate: boolean
  measure: string
  /** HTML for the icon */
  icon: string
  message: string
}

export const CANCEL_ICON: string
export function rowView(tree: TaskTree, node: Node | Fold): RowView
