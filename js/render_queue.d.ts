import type { TaskTree } from "./task_tree.js"

/** What changed since the last draw - see "Drawing once a frame" in the MANUAL */
export interface Changes {
  batches: number
  /** Keys of the nodes changed, and every one above them */
  touched: Set<string>
  /** What a renderer must not miss, in order: done, fail, cancel, say, reset, gap */
  events: Array<{ op: string; path: string[]; value?: unknown }>
  /** Rows came, went or moved */
  structure: boolean
  local: boolean
}

export type Schedule = (draw: () => void) => void
export const nextFrame: Schedule

export class RenderQueue {
  constructor(tree: TaskTree, onFrame: (tree: TaskTree, changes: Changes) => void, options?: { schedule?: Schedule })
  apply(batch: Batch): ApplyOutcome
  close(): void
}

import type { Batch, ApplyOutcome } from "./task_tree.js"
