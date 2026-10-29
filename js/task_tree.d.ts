import type { Path } from "./paths.js"
import type { Changes, Schedule } from "./render_queue.js"

export { pathKey, pathFromKey } from "./paths.js"
export type { Path } from "./paths.js"
export type { Changes } from "./render_queue.js"

/** One op: `[path, op, value]` - see the wire format in the MANUAL */
export type Op = [Path, string] | [Path, string, unknown]

/** A batch, as TaskProgress::Wire writes it */
export interface Batch {
  v: 1
  log: string
  prev: number
  seq: number
  at: number
  ops: Op[]
}

export type Status = "pending" | "active" | "done" | "failed" | "canceled"

/** One task, as the tree holds it */
export interface Node {
  path: Path
  name: string
  total: number | null
  count: number
  percent: number
  weight: number
  expect: number | null
  indeterminate: boolean
  cancelable: boolean
  attempt: number | null
  unit: string | null
  message: string | null
  status: Status
  error: { class: string; message: string; backtrace?: string[] } | null
  stale: boolean
  opened_at: number
  started_at: number | null
  finished_at: number | null
  children: string[]
}

/** Siblings drawn as one row, see TaskTree#rows */
export interface Fold {
  fold: true
  path: Path
  status: "done" | "pending"
  count: number
}

export type ApplyOutcome = "applied" | "duplicate" | "gap" | "unsupported"

/** What TaskProgress.for_page hands a page */
export interface Progress {
  events?: string
  poll?: string
  cancel?: string
  snapshot?: Batch
}

export const WIRE_VERSION: 1
export const FOLD_OVER: number
export const FOLD_KEEP: number

export class TaskTree {
  constructor(options?: { clock?: () => number })
  log: string | null
  seq: number | null
  stale: boolean
  readonly root: Node | undefined
  apply(batch: Batch): ApplyOutcome
  get(path: Path): Node | undefined
  childrenOf(node: Node): Node[]
  each(node?: Node): Generator<Node>
  rows(node?: Node, options?: { foldOver?: number; keep?: number }): Generator<Node | Fold>
  complete(node: Node): boolean
  fraction(node: Node): number
  percentOf(node: Node): number
  now(): number
  /** The LocalTasks this whole tree mirrors, see followLocal */
  local: import("./local_tasks.js").LocalTasks | null
  graft(path: Path, local: import("./local_tasks.js").LocalTasks): () => void
  cancelLocal(path: Path, reason?: string): void
}

export interface Following {
  readonly tree: TaskTree
  close(): void
}

export interface FeedOptions {
  schedule?: Schedule
  clock?: () => number
  /** A batch to start from - the snapshot a page was rendered with */
  initial?: Batch
}

export type OnChange = (tree: TaskTree, changes: Changes) => void

export function batchFeed(onChange: OnChange, options?: FeedOptions): Following & { push(batch: Batch): ApplyOutcome }
export function followEventSourceAt(url: string, onChange: OnChange, options?: FeedOptions & { onUnreachable?: () => void; unreachableAfter?: number }): Following
/** `poll` and `wait` are in seconds */
export function followPollingAt(url: string, onChange: OnChange, options?: FeedOptions & { poll?: number; wait?: number }): Following
/** Draws tasks that run in this browser on their own, with no server tree around them */
export function followLocal(local: import("./local_tasks.js").LocalTasks, onChange: OnChange, options?: FeedOptions): Following
export function followProgress(progress: Progress, onChange: OnChange, options?: FeedOptions & { transport?: "auto" | "sse" | "poll"; poll?: number; wait?: number; unreachableAfter?: number }): Following
export function requestCancel(url: string, path: Path, options?: { token?: string }): Promise<Response>
export function humanBytes(n: number): string
