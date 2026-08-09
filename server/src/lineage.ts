/**
 * SPEC-46 D9/T11 — the spawn-tree bounds, computed from persisted lineage.
 *
 * D9 derives a spawn's `parentId` from the credential, so an agent can forge
 * nothing here. But persisted lineage is still not trusted blindly: a
 * `parentId` written before a crash, or a hand-edited database, can contain a
 * cycle or point at a session that was killed. So the depth walk terminates on
 * a repeated id and on a missing ancestor, and never throws — the guard must
 * hold against hostile data, not just well-formed data.
 */

/** The single lineage fact each session contributes to the walk. */
export interface LineageNode {
  readonly id: string;
  readonly parentId?: string;
  /** Archived sessions are not counted as live children (SPEC-29). */
  readonly archived?: boolean;
}

/** A child may sit at most this deep (a chain of MAX_SPAWN_DEPTH spawns). */
export const MAX_SPAWN_DEPTH = 3;
/** A session may have at most this many live (non-archived) children. */
export const MAX_LIVE_CHILDREN = 4;

/**
 * Depth the child of `parentId` would occupy: 1 for the child of a root
 * session, +1 per ancestor link walked upward. Terminates on a cycle (a
 * repeated id) and on a missing ancestor (an id absent from `nodes` ends the
 * walk); it never throws.
 */
export function spawnDepth(parentId: string, nodes: ReadonlyMap<string, LineageNode>): number {
  const seen = new Set<string>();
  let current: string | undefined = parentId;
  let depth = 0;
  while (current !== undefined && !seen.has(current)) {
    seen.add(current);
    depth += 1;
    current = nodes.get(current)?.parentId;
  }
  return depth;
}

/** Live (non-archived) sessions whose parent is `parentId`. */
export function liveChildCount(parentId: string, nodes: Iterable<LineageNode>): number {
  let n = 0;
  for (const node of nodes) {
    if (node.parentId === parentId && !node.archived) n += 1;
  }
  return n;
}

/**
 * The reason a new child of `parentId` may not be spawned, or `null` when it
 * may. The message names the limit it hit, because the caller (an agent's
 * shell-out) needs to know which bound stopped it (D9).
 */
export function spawnBoundError(
  parentId: string,
  nodes: ReadonlyMap<string, LineageNode>,
): string | null {
  if (spawnDepth(parentId, nodes) > MAX_SPAWN_DEPTH) {
    return `spawn refused: the session tree is at its maximum depth of ${MAX_SPAWN_DEPTH}`;
  }
  if (liveChildCount(parentId, nodes.values()) >= MAX_LIVE_CHILDREN) {
    return `spawn refused: this session already has the maximum of ${MAX_LIVE_CHILDREN} live children`;
  }
  return null;
}
