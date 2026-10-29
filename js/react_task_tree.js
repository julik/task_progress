import React, { useEffect, useRef, useState } from "react"
import { createRoot } from "react-dom/client"
import { followEventSourceAt, followLocal, followPollingAt, followProgress, requestCancel } from "./task_tree.js"
import { rowView, CANCEL_ICON } from "./row_view.js"

// No JSX, so it runs as it is - in a Vite app, or straight off an import map with no build step
const h = React.createElement

const NO_GRAFTS = []
const FINISHED = new Set(["done", "failed", "canceled"])

// Follows a tree: what TaskProgress.for_page hands a page - { events, poll, cancel, snapshot },
// drawn from its snapshot at once - or the url of a TaskProgress::SSE stream, or of a
// TaskProgress::Poll endpoint given `poll` (seconds between polls) or `wait` (seconds to
// long-poll). `transport` picks for a for_page object, see followProgress. Or a LocalTasks, for
// tasks that run in this browser alone - uploads, say - drawn as they change, with no server.
//
// Returns { tree, rows, cancel }: the tree, what to draw (see rowView), and a function that asks
// for a row's task to be canceled - a task running in this browser is canceled here. `onComplete`
// and `onFail` are called once, when the root has finished one way or the other - for an
// Inertia page, `onComplete: () => router.reload({ only: ["video"] })`. `grafts` - [{ path, local }]
// - draws tasks running in this browser under server tasks, see TaskTree#graft
export function useTaskTree(source, { transport, poll = 0, wait = 0, grafts = NO_GRAFTS, onComplete, onFail } = {}) {
  const [state, setState] = useState({ tree: null, version: 0 })
  const callbacks = useRef({})
  callbacks.current = { onComplete, onFail }
  const local = typeof source?.subscribe === "function" ? source : null
  const progress = typeof source === "string" || local ? null : source
  const url = typeof source === "string" ? source : null
  // A for_page object is a new object every render; what it points at is what matters
  const followKey = local ? local.log : progress ? `${progress.events} ${progress.poll}` : url
  useEffect(() => {
    setState({ tree: null, version: 0 })
    if (!followKey) return
    let told = false
    const draw = (tree) => {
      setState((s) => ({ tree, version: s.version + 1 }))
      const status = tree.root?.status
      if (told || !FINISHED.has(status)) return
      told = true
      if (status === "done") callbacks.current.onComplete?.(tree)
      else callbacks.current.onFail?.(tree)
    }
    const following = local
      ? followLocal(local, draw)
      : progress
      ? followProgress(progress, draw, { transport, poll: poll || 1, wait })
      : poll || wait ? followPollingAt(url, draw, { poll: poll || 1, wait }) : followEventSourceAt(url, draw)
    return () => following.close()
  }, [followKey, transport, poll, wait]) // eslint-disable-line react-hooks/exhaustive-deps
  // Keyed on what the grafts are, not on the array: one written inline is a new array every
  // render, and grafting anew draws again - which would render again, every frame, for ever
  const graftsKey = grafts.map(({ path, local }) => `${path.join("-")}:${local.log}`).join(" ")
  useEffect(() => {
    if (!state.tree) return
    const ungrafts = grafts.map(({ path, local }) => state.tree.graft(path, local))
    return () => ungrafts.forEach((ungraft) => ungraft())
  }, [state.tree, graftsKey]) // eslint-disable-line react-hooks/exhaustive-deps
  const { tree } = state
  const rows = tree ? [...tree.rows()].map((node) => rowView(tree, node)) : []
  const cancelUrl = progress?.cancel
  const cancel = async (row) => {
    if (row.local) return tree?.cancelLocal(row.path, "Canceled in this browser")
    if (!cancelUrl) return false
    try { return (await requestCancel(cancelUrl, row.path)).ok } catch { return false }
  }
  return { tree, rows, cancel: cancelUrl ? cancel : (row) => (row.local ? cancel(row) : false), canCancel: !!cancelUrl }
}

// A cancel button, right of the bar. It stays pressed until the cancel comes down the stream -
// the row is then not cancelable any more, and the button hides. Hidden, it keeps its place
function CancelButton({ row, onCancel, offered }) {
  const [pressed, setPressed] = useState(false)
  const press = async () => {
    setPressed(true)
    if ((await onCancel(row)) === false) setPressed(false)
  }
  return h("button", {
    type: "button", className: "cancel", hidden: !(offered && row.cancelable), disabled: pressed,
    "aria-label": `Cancel ${row.name}`, onClick: press, dangerouslySetInnerHTML: { __html: CANCEL_ICON }
  })
}

function Row({ row, onCancel, offered }) {
  return h("div", { className: `row ${row.status}${row.stale ? " stale" : ""}${row.folded ? " folded" : ""}` },
    h("div", { className: "label", style: { paddingLeft: row.depth * 18 } },
      h("span", { className: "icon", dangerouslySetInnerHTML: { __html: row.icon } }),
      h("span", { className: "name" }, row.name),
      h("span", { className: "message" }, row.message)),
    h("div", { className: `bar${row.indeterminate ? " indeterminate" : ""}` }, h("span", { style: { width: `${row.percent}%` } })),
    h(CancelButton, { row, onCancel, offered }),
    h("div", { className: "measure" }, row.measure))
}

// The tree as rows, styled by task_tree.css. Give it `progress` - what TaskProgress.for_page
// hands a page - or a `url`, as useTaskTree takes them, or `local`, a LocalTasks. With a `url`, `cancelUrl` and
// `cancelToken` say where cancel buttons ask; with `progress` they ask where it says. For
// anything else, pass `onCancel(row)` - return false from it to release the button. `onComplete`
// and `onFail` are called once the root has finished
export function TaskTreeView({ progress, url, local, cancelUrl, cancelToken, onCancel, onComplete, onFail, grafts, transport, poll, wait }) {
  const { tree, rows, cancel, canCancel } = useTaskTree(local ?? progress ?? url, { transport, poll, wait, grafts, onComplete, onFail })
  if (!tree) return null
  const remote = !progress && cancelUrl && (async (row) => {
    try { return (await requestCancel(cancelUrl, row.path, { token: cancelToken })).ok } catch { return false }
  })
  const onPress = onCancel ?? ((row) => (row.local || !remote ? cancel(row) : remote(row)))
  // A server task can only be asked to cancel where there is somewhere to ask
  const offered = (row) => !!(onCancel || canCancel || remote || row.local)
  // Rows alone, for an element of yours with the `tree` class around them
  return h(React.Fragment, null, rows.map((row) => h(Row, { key: row.key, row, onCancel: onPress, offered: offered(row) })))
}

// For pages that are not React apps, as React's own createRoot: render it into an element, and
// render again with other props - another url, `poll` - to change what it follows
//
//   createTaskTreeRoot(element).render({ progress })   // or { url: "/jobs/42/progress" }
export function createTaskTreeRoot(element) {
  const root = createRoot(element)
  return {
    render: (props) => root.render(h(TaskTreeView, props)),
    unmount: () => root.unmount()
  }
}
