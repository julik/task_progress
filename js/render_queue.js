// A stream can carry thousands of batches a second, far more than a screen can show. Every batch is
// still folded into the tree as it arrives - the seq chain and the parity with Ruby depend on that -
// but the renderer gets called at most once a frame, with what changed since the last call.
//
// A set, add or note only matters for the state it leaves behind, so those collapse into the paths
// they touched. What a renderer must hear about even when a later batch in the same frame hides it
// goes into `events`, in order: done, fail (with the error) and cancel, say lines (the tree never holds
// them), and the stream starting over (reset) or breaking off (gap).

const key = (path) => path.join("/")

// requestAnimationFrame follows the display and pauses in a background tab; Node has neither
export const nextFrame = globalThis.requestAnimationFrame
  ? (fn) => globalThis.requestAnimationFrame(fn)
  : (fn) => setTimeout(fn, 16)

const STRUCTURAL = new Set(["open", "put", "prune"])
const NOTABLE = new Set(["done", "fail", "cancel", "say"])

const blankChanges = () => ({ batches: 0, touched: new Set(), events: [], structure: false })

export class RenderQueue {
  // onFrame(tree, changes) - changes is { batches, touched, events, structure }. `structure` says
  // rows came, went or moved, so a renderer that patches rows in place has to lay them out again
  constructor(tree, onFrame, { schedule = nextFrame } = {}) {
    this.tree = tree
    this.onFrame = onFrame
    this.schedule = schedule
    this.changes = blankChanges()
    this.pending = false
    this.closed = false
  }

  apply(batch) {
    const result = this.tree.apply(batch)
    const changes = this.changes
    changes.batches++
    if (batch.prev === 0) {
      changes.events.push({ op: "reset", seq: batch.seq })
      changes.structure = true
    }
    if (result === "gap") changes.events.push({ op: "gap", seq: batch.seq, prev: batch.prev })
    if (result === "applied") for (const [path, op, value] of batch.ops) this.#note(path, op, value, batch.seq)
    this.#request()
    return result
  }

  // Hands over what has piled up right away, without waiting for the frame
  flush() {
    this.pending = false
    if (this.closed) return
    const changes = this.changes
    if (changes.batches === 0) return
    this.changes = blankChanges()
    this.onFrame(this.tree, changes)
  }

  // A frame already asked for must not draw an old stream into a renderer that moved on
  close() { this.closed = true }

  #note(path, op, value, seq) {
    // Percents roll up, so a change anywhere shows in every row above it too
    for (let length = path.length; length >= 0; length--) this.changes.touched.add(key(path.slice(0, length)))
    if (STRUCTURAL.has(op)) this.changes.structure = true
    if (NOTABLE.has(op)) this.changes.events.push({ op, path, value: value ?? null, seq })
  }

  #request() {
    if (this.pending || this.closed) return
    this.pending = true
    this.schedule(() => this.flush())
  }
}
