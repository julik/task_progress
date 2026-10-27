import React, { useEffect, useState } from "react"
import { createRoot } from "react-dom/client"
import htm from "htm"
import { follow } from "./task_tree.js"
import { rowView } from "./row_view.js"

const html = htm.bind(React.createElement)

// Follows a TaskProgress SSE stream. The tree object stays the same one, so a version counter
// is what tells React to render again
export function useTaskTree(url) {
  const [state, setState] = useState({ tree: null, version: 0 })
  useEffect(() => {
    setState({ tree: null, version: 0 })
    if (!url) return
    const following = follow(url, (tree) => setState((s) => ({ tree, version: s.version + 1 })))
    return () => following.close()
  }, [url])
  return state.tree
}

function Row({ row }) {
  return html`
    <div className=${`row ${row.status}${row.stale ? " stale" : ""}`}>
      <div className="label" style=${{ paddingLeft: row.depth * 18 }}>
        <span className="icon" dangerouslySetInnerHTML=${{ __html: row.icon }} />
        <span className="name">${row.name}</span>
        <span className="message">${row.message}</span>
      </div>
      <div className=${`bar${row.indeterminate ? " indeterminate" : ""}`}><span style=${{ width: `${row.percent}%` }} /></div>
      <div className="measure">${row.measure}</div>
    </div>`
}

export function TaskTreeView({ url }) {
  const tree = useTaskTree(url)
  if (!tree) return null
  return [...tree.each()].map((node) => rowView(tree, node)).map((row) => html`<${Row} key=${row.key} row=${row} />`)
}

// For pages that are not React apps: mount into an element, then point it at streams
export function mountTaskTree(element) {
  const root = createRoot(element)
  return { follow: (url) => root.render(html`<${TaskTreeView} url=${url} />`) }
}
