import { Controller } from "@hotwired/stimulus"
import type { Path } from "./task_tree.js"
import type { LocalTasks } from "./local_tasks.js"

/** Register as "task-tree" - see the MANUAL */
export default class TaskTreeController extends Controller {
  graft(path: Path, local: LocalTasks): void
}
