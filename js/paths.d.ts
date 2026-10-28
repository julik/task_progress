/** A task's place in the tree: its ancestors' ids, then its own - `[]` is the root */
export type Path = string[]
/** A path's key - its ids joined with a dash, `""` for the root */
export function pathKey(path: Path): string
export function pathFromKey(key: string): Path
