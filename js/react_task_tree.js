import React, { useEffect, useState } from "react"
import { createRoot } from "react-dom/client"
import htm from "htm"
import { followEventSourceAt, followPollingAt, requestCancel } from "./task_tree.js"
import { rowView, CANCEL_ICON } from "./row_view.js"

const html = htm.bind(React.createElement)

const NO_GRAFTS = []

// Follows a TaskProgress SSE stream - or polls a TaskProgress::Poll endpoint, given `poll`
// (seconds between polls) or `wait` (seconds to long-poll), see followPollingAt. The tree object
// stays the same one, so a version counter is what tells React to render again. `grafts` -
// [{ path, local }] - draws tasks running in this browser under server tasks, see
// TaskTree#graft; keep the array the same one while it does not change
export function useTaskTree(url, grafts = NO_GRAFTS, { poll = 0, wait = 0 } = {}) {
  const [state, setState] = useState({ tree: null, version: 0 })
  useEffect(() => {
    setState({ tree: null, version: 0 })
    if (!url) return
    const draw = (tree) => setState((s) => ({ tree, version: s.version + 1 }))
    const following = poll || wait ? followPollingAt(url, draw, { interval: (poll || 1) * 1000, wait }) : followEventSourceAt(url, draw)
    return () => following.close()
  }, [url, poll, wait])
  useEffect(() => {
    if (!state.tree) return
    const ungrafts = grafts.map(({ path, local }) => state.tree.graft(path, local))
    return () => ungrafts.forEach((ungraft) => ungraft())
  }, [state.tree, grafts])
  return state.tree
}

// A cancel button, right of the bar. It stays pressed until the cancel comes down the stream -
// the row is then not cancelable any more, and the button hides. Hidden, it keeps its place
function CancelButton({ row, onCancel, offered }) {
  const [pressed, setPressed] = useState(false)
  const press = async () => {
    setPressed(true)
    if ((await onCancel(row)) === false) setPressed(false)
  }
  return html`<button type="button" className="cancel" hidden=${!(offered && row.cancelable)} disabled=${pressed}
    aria-label=${`Cancel ${row.name}`} onClick=${press} dangerouslySetInnerHTML=${{ __html: CANCEL_ICON }} />`
}

function Row({ row, onCancel, offered }) {
  return html`
    <div className=${`row ${row.status}${row.stale ? " stale" : ""}${row.folded ? " folded" : ""}`}>
      <div className="label" style=${{ paddingLeft: row.depth * 18 }}>
        <span className="icon" dangerouslySetInnerHTML=${{ __html: row.icon }} />
        <span className="name">${row.name}</span>
        <span className="message">${row.message}</span>
      </div>
      <div className=${`bar${row.indeterminate ? " indeterminate" : ""}`}><span style=${{ width: `${row.percent}%` }} /></div>
      <${CancelButton} row=${row} onCancel=${onCancel} offered=${offered} />
      <div className="measure">${row.measure}</div>
    </div>`
}

// `cancelUrl` gets a cancellation created at it when a cancel button is pressed, signed with
// `cancelToken`; a task running in this browser is canceled here. For anything else, pass
// `onCancel(row)` - return false from it to release the button
export function TaskTreeView({ url, cancelUrl, cancelToken, onCancel, grafts, poll, wait }) {
  const tree = useTaskTree(url, grafts, { poll, wait })
  if (!tree) return null
  const remote = cancelUrl && (async (row) => {
    try { return (await requestCancel(cancelUrl, row.path, { token: cancelToken })).ok } catch { return false }
  })
  const cancel = onCancel ?? ((row) => (row.local ? tree.cancelLocal(row.path, "Canceled in this browser") : remote?.(row)))
  // A server task can only be asked to cancel where there is somewhere to ask
  return [...tree.rows()].map((node) => rowView(tree, node))
    .map((row) => html`<${Row} key=${row.key} row=${row} onCancel=${cancel} offered=${!!(onCancel || remote || row.local)} />`)
}

// For pages that are not React apps: mount into an element, then point it at streams
export function mountTaskTree(element) {
  const root = createRoot(element)
  return { followEventSourceAt: (url, props = {}) => root.render(html`<${TaskTreeView} url=${url} ...${props} />`) }
}
