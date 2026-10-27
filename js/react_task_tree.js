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
// TaskTree#graft
export function useTaskTree(url, { poll = 0, wait = 0, grafts = NO_GRAFTS } = {}) {
  const [state, setState] = useState({ tree: null, version: 0 })
  useEffect(() => {
    setState({ tree: null, version: 0 })
    if (!url) return
    const draw = (tree) => setState((s) => ({ tree, version: s.version + 1 }))
    const following = poll || wait ? followPollingAt(url, draw, { poll: poll || 1, wait }) : followEventSourceAt(url, draw)
    return () => following.close()
  }, [url, poll, wait])
  // Keyed on what the grafts are, not on the array: one written inline is a new array every
  // render, and grafting anew draws again - which would render again, every frame, for ever
  const graftsKey = grafts.map(({ path, local }) => `${path.join("-")}:${local.log}`).join(" ")
  useEffect(() => {
    if (!state.tree) return
    const ungrafts = grafts.map(({ path, local }) => state.tree.graft(path, local))
    return () => ungrafts.forEach((ungraft) => ungraft())
  }, [state.tree, graftsKey]) // eslint-disable-line react-hooks/exhaustive-deps
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
  const tree = useTaskTree(url, { poll, wait, grafts })
  if (!tree) return null
  const remote = cancelUrl && (async (row) => {
    try { return (await requestCancel(cancelUrl, row.path, { token: cancelToken })).ok } catch { return false }
  })
  const cancel = onCancel ?? ((row) => (row.local ? tree.cancelLocal(row.path, "Canceled in this browser") : remote?.(row)))
  // A server task can only be asked to cancel where there is somewhere to ask
  return [...tree.rows()].map((node) => rowView(tree, node))
    .map((row) => html`<${Row} key=${row.key} row=${row} onCancel=${cancel} offered=${!!(onCancel || remote || row.local)} />`)
}

// For pages that are not React apps, as React's own createRoot: render it into an element, and
// render again with other props - another url, `poll` - to change what it follows
//
//   createTaskTreeRoot(element).render({ url: "/jobs/42/progress" })
export function createTaskTreeRoot(element) {
  const root = createRoot(element)
  return {
    render: (props) => root.render(html`<${TaskTreeView} ...${props} />`),
    unmount: () => root.unmount()
  }
}
