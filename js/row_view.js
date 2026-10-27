import { humanBytes } from "./task_tree.js"

const GLYPHS = { done: "✓", failed: "✗", canceled: "⊘", pending: "·" }
const FINISHED = new Set(["done", "failed", "canceled"])

// A circle with a cross in it, drawn in the row's text color - the same in every font
export const CANCEL_ICON = '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M5.6 5.6l4.8 4.8M10.4 5.6l-4.8 4.8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>'

// What one row shows, worked out once for both demos
export function rowView(tree, node) {
  const percent = tree.percentOf(node)
  const leaf = node.children.length === 0
  const indeterminate = leaf && node.indeterminate && node.status === "active"
  let measure = `${percent}%`
  if (leaf && node.total != null) {
    measure = node.unit === "bytes" ? `${humanBytes(node.count)} / ${humanBytes(node.total)}` : `${node.count} / ${node.total}`
  } else if (indeterminate) {
    measure = elapsed(tree, node)
  }
  // Every state is one inner span, so the .icon box around it never changes; the spinner is drawn in CSS
  const glyph = GLYPHS[node.status]
  const icon = glyph ? `<span>${glyph}</span>` : '<span class="spin"></span>'
  return {
    key: node.path.join("/"), path: node.path, depth: node.path.length, name: node.name, status: node.status, stale: node.stale,
    cancelable: !!node.cancelable && !FINISHED.has(node.status),
    percent, indeterminate, measure, icon,
    message: node.status === "failed" ? node.error?.message ?? "" : [pace(tree, node), node.message].filter(Boolean).join(" · ")
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
