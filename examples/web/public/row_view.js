import { humanBytes } from "/task_tree.js"

const GLYPHS = { done: "✓", failed: "✗", pending: "·" }

// What one row shows, worked out once for both demos
export function rowView(tree, node) {
  const percent = tree.percentOf(node)
  const leaf = node.children.length === 0
  const indeterminate = leaf && node.indeterminate && node.status === "active"
  let measure = `${percent}%`
  if (leaf && node.total != null) {
    measure = node.unit === "bytes" ? `${humanBytes(node.count)} / ${humanBytes(node.total)}` : `${node.count} / ${node.total}`
  } else if (indeterminate) {
    measure = elapsed(node)
  }
  // Every state is one inner span, so the .icon box around it never changes; the spinner is drawn in CSS
  const glyph = GLYPHS[node.status]
  const icon = glyph ? `<span>${glyph}</span>` : '<span class="spin"></span>'
  return {
    key: node.path.join("/"), depth: node.path.length, name: node.name, status: node.status, stale: node.stale,
    percent, indeterminate, measure, icon,
    message: node.status === "failed" ? node.error?.message ?? "" : node.message ?? ""
  }
}

function elapsed(node) {
  if (!node.started_at) return ""
  return `${Math.max(0, Date.now() / 1000 - node.started_at).toFixed(1)}s`
}
