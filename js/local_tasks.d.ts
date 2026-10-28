import type { Batch, Node, Status, Path } from "./task_tree.js"

export interface LocalTaskOptions {
  total?: number
  weight?: number
  expect?: number
  indeterminate?: boolean
  unit?: string
  cancelable?: boolean
  autofinish?: boolean
}

/** Tasks that run in this browser, grafted under a server task with TaskTree#graft */
export class LocalTasks {
  constructor(name: string, options?: LocalTaskOptions & { clock?: () => number })
  readonly log: string
  readonly root: LocalTask
  subscribe(fn: (batch: Batch) => void): () => void
  squash(): Batch
  at(path: Path): LocalTask | null
}

export class LocalTask {
  readonly path: Path
  readonly node: Node
  readonly status: Status
  readonly finished: boolean
  readonly canceled: boolean
  /** Aborts when the task is canceled - for fetch, say */
  readonly signal: AbortSignal
  subtask(name: string, options?: LocalTaskOptions): LocalTask | null
  advance(by?: number, options?: { message?: string }): this
  tick(options?: { message?: string }): this
  update(percent: number, options?: { message?: string }): this
  note(message: string): this
  setTotal(total: number): this
  done(): this
  fail(error?: unknown): this
  cancel(reason?: string): this
  onCancel(handler: (reason?: string) => void): this
  whenFinished(): Promise<Status>
}

export function trackUpload(xhr: XMLHttpRequest, task: LocalTask, options?: { abortOnCancel?: boolean }): LocalTask
