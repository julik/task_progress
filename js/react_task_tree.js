import React, { useEffect, useState } from "react"
import { createRoot } from "react-dom/client"
import htm from "htm"
import { followEventSourceAt, requestCancel } from "./task_tree.js"
import { rowView, CANCEL_ICON } from "./row_view.js"

const html = htm.bind(React.createElement)

// Follows a TaskProgress SSE stream. The tree object stays the same one, so a version counter
// is what tells React to render again
export function useTaskTree(url) {
  const [state, setState] = useState({ tree: null, version: 0 })
  useEffect(() => {
    setState({ tree: null, version: 0 })
    if (!url) return
    const following = followEventSourceAt(url, (tree) => setState((s) => ({ tree, version: s.version + 1 })))
    return () => following.close()
  }, [url])
  return state.tree
}

// A cancel button, right of the bar. It stays pressed until the cancel comes down the stream -
// the row is then not cancelable any more, and the button hides. Hidden, it keeps its place
function CancelButton({ row, onCancel }) {
  const [pressed, setPressed] = useState(false)
  const press = async () => {
    setPressed(true)
    if ((await onCancel(row)) === false) setPressed(false)
  }
  return html`<button type="button" className="cancel" hidden=${!(onCancel && row.cancelable)} disabled=${pressed}
    aria-label=${`Cancel ${row.name}`} onClick=${press} dangerouslySetInnerHTML=${{ __html: CANCEL_ICON }} />`
}

function Row({ row, onCancel }) {
  return html`
    <div className=${`row ${row.status}${row.stale ? " stale" : ""}`}>
      <div className="label" style=${{ paddingLeft: row.depth * 18 }}>
        <span className="icon" dangerouslySetInnerHTML=${{ __html: row.icon }} />
        <span className="name">${row.name}</span>
        <span className="message">${row.message}</span>
      </div>
      <div className=${`bar${row.indeterminate ? " indeterminate" : ""}`}><span style=${{ width: `${row.percent}%` }} /></div>
      <${CancelButton} row=${row} onCancel=${onCancel} />
      <div className="measure">${row.measure}</div>
    </div>`
}

// `cancelUrl` gets a cancellation created at it when a cancel button is pressed, signed with
// `cancelToken`. For anything else, pass `onCancel(row)` - return false from it to release the button
export function TaskTreeView({ url, cancelUrl, cancelToken, onCancel }) {
  const tree = useTaskTree(url)
  if (!tree) return null
  const cancel = onCancel ?? (cancelUrl && (async (row) => {
    try { return (await requestCancel(cancelUrl, row.path, { token: cancelToken })).ok } catch { return false }
  }))
  return [...tree.each()].map((node) => rowView(tree, node)).map((row) => html`<${Row} key=${row.key} row=${row} onCancel=${cancel} />`)
}

// For pages that are not React apps: mount into an element, then point it at streams
export function mountTaskTree(element) {
  const root = createRoot(element)
  return { followEventSourceAt: (url, props = {}) => root.render(html`<${TaskTreeView} url=${url} ...${props} />`) }
}
