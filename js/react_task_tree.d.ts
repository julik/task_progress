import type { ReactElement } from "react"
import type { TaskTree, Progress, Path } from "./task_tree.js"
import type { RowView } from "./row_view.js"
import type { LocalTasks } from "./local_tasks.js"

export type { Progress } from "./task_tree.js"
export type { RowView } from "./row_view.js"

export interface Graft { path: Path; local: LocalTasks }

export interface FollowOptions {
  transport?: "auto" | "sse" | "poll"
  /** Seconds between polls */
  poll?: number
  /** Seconds to long-poll */
  wait?: number
  grafts?: Graft[]
  /** Called once, when the root is done - `() => router.reload({ only: ["video"] })` */
  onComplete?: (tree: TaskTree) => void
  /** Called once, when the root failed or was canceled */
  onFail?: (tree: TaskTree) => void
}

export interface UseTaskTree {
  tree: TaskTree | null
  rows: RowView[]
  /** Asks for the row's task to be canceled; resolves false if it could not ask */
  cancel(row: RowView): Promise<boolean | undefined> | boolean | undefined
  canCancel: boolean
}

/** Follows what TaskProgress.for_page hands a page, or the url of an SSE stream or Poll endpoint */
export function useTaskTree(source: Progress | string | null | undefined, options?: FollowOptions): UseTaskTree

export interface TaskTreeViewProps extends FollowOptions {
  progress?: Progress
  url?: string
  cancelUrl?: string
  cancelToken?: string
  /** Return false to release the button */
  onCancel?: (row: RowView) => unknown
}

/** The rows, for an element of yours with the `tree` class around them */
export function TaskTreeView(props: TaskTreeViewProps): ReactElement | null

export function createTaskTreeRoot(element: Element): { render(props: TaskTreeViewProps): void; unmount(): void }
