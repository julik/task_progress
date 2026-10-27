import { humanBytes } from "./task_tree.js"
import { pathKey } from "./paths.js"

const GLYPHS = { done: "✓", failed: "✗", canceled: "⊘", pending: "·" }
const FINISHED = new Set(["done", "failed", "canceled"])

// A circle with a cross in it, drawn in the row's text color - the same in every font
export const CANCEL_ICON = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M5.6 5.6l4.8 4.8M10.4 5.6l-4.8 4.8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>'

// What one row shows, worked out once for both demos - a task, or siblings folded into one row
// (see TaskTree#rows)
export function rowView(tree, node) {
  if (node.fold) return foldView(node)
  const percent = tree.percentOf(node)
  const leaf = node.children.length === 0
  const indeterminate = leaf && node.indeterminate && node.status === "active"
  let measure = `${percent}%`
  if (leaf && node.total != null) {
    measure = node.unit === "bytes" ? `${humanBytes(node.count)} / ${humanBytes(node.total)}` : `${node.count} / ${node.total}`
  } else if (indeterminate) {
    measure = elapsed(tree, node)
  }
  // A task called done with something still running under it - browser work grafted to it, say -
  // is not through, and is drawn as running until it is
  const status = node.status === "done" && !tree.complete(node) ? "active" : node.status
  // Every state is one inner span, so the .icon box around it never changes; the spinner is drawn in CSS
  const glyph = GLYPHS[status]
  const icon = glyph ? `<span>${glyph}</span>` : '<span class="spin"></span>'
  return {
    key: pathKey(node.path), path: node.path, depth: node.path.length, name: node.name, status, stale: node.stale,
    local: node.path.some((id) => String(id).startsWith("_")), // runs in this browser, see LocalTasks
    cancelable: !!node.cancelable && !FINISHED.has(node.status),
    percent, indeterminate, measure, icon,
    message: [node.attempt > 1 ? `attempt ${node.attempt}` : null,
      node.status === "failed" ? node.error?.message : [pace(tree, node), node.message].filter(Boolean).join(" · ")].filter(Boolean).join(" · ")
  }
}

function foldView({ path, status, count }) {
  const done = status === "done"
  return {
    key: pathKey(path), path, depth: path.length, name: `${count.toLocaleString("en-US")} more ${done ? "done" : "waiting"}`,
    status, stale: false, local: false, cancelable: false, folded: true,
    percent: done ? 100 : 0, indeterminate: false, measure: "", icon: `<span>${GLYPHS[status]}</span>`, message: ""
  }
}

// The rate over the run so far and the time left at it, as the terminal shows them
function pace(tree, node) {
  if (node.status !== "active" || node.children.length > 0 || !node.started_at || node.count === 0) return ""
  const seconds = tree.now() - node.started_at
  if (seconds < 1) return ""
  const rate = node.count / seconds
  const per = node.unit === "bytes" ? `${humanBytes(rate)}/s` : `${rate < 10 ? rate.toFixed(1) : Math.floor(rate)}/s`
  if (node.total == null || node.total <= node.count) return per
  return `${per}, ${duration((node.total - node.count) / rate)} left`
}

function duration(seconds) {
  if (seconds < 60) return `${seconds.toFixed(1)}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m${String(Math.floor(seconds % 60)).padStart(2, "0")}s`
  return `${Math.floor(seconds / 3600)}h${String(Math.floor((seconds % 3600) / 60)).padStart(2, "0")}m`
}

// Measured on the clock the times came from, never this machine's
function elapsed(tree, node) {
  if (!node.started_at) return ""
  return `${Math.max(0, (node.finished_at ?? tree.now()) - node.started_at).toFixed(1)}s`
}
