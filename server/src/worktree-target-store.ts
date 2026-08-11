/**
 * worktree-target-store — persistence for each worktree's **target branch**:
 * the branch its work is destined for, which decides what the `+N −M` diff
 * measures, what a PR targets, and what a wrap-up fast-forwards.
 *
 * Why a new store at all: nothing in makit persisted per-worktree state.
 * `projects.json` holds `{ id, path }` records only, and worktrees are
 * enumerated live from `git worktree list` on every snapshot — so the base
 * branch the user picked at creation time was used once for `git worktree add`
 * and then discarded. This is the missing home for that answer.
 *
 * Keyed by **absolute worktree path**, which is the same identity
 * `WorktreeDTO.id` uses. Path-keying survives a branch rename (`renameBranch`
 * keeps the path) but it does NOT survive a move, and — the sharp edge — a
 * removed-and-recreated worktree lands on the *same* path, because
 * `addWorktree` builds `<baseDir>/<repoName>/<name>` deterministically. Without
 * {@link pruneTargets} the new worktree would silently inherit the dead one's
 * target. Callers must prune against the live set.
 *
 * Like `project-store`, load/save never throw: a corrupt or unreadable file
 * degrades to "no targets" so the server always starts, and a failed write is
 * logged and swallowed. Unlike `project-store`, the write is **atomic**
 * (temp file + rename), because a torn read-modify-write here would silently
 * lose or corrupt a value that decides where code gets merged.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { makitHome } from "./daemon/paths.js";
import { log } from "./log.js";

/**
 * One worktree's target, plus what it used to be when makit changed it on the
 * user's behalf.
 */
export interface TargetEntry {
  /** The branch this worktree's work lands in. */
  target: string;
  /**
   * The target this replaced, when the change was **automatic** — a branch we
   * were aiming at disappeared and we fell back to the repo default.
   *
   * Kept so the change can be *announced* rather than done behind the user's
   * back: a silent repoint would move a worktree's diff and its future pull
   * request to a different destination with no trace. Cleared the moment the user
   * chooses a target explicitly, because by then they own the value and there is
   * nothing left to tell them.
   */
  retargetedFrom?: string;
}

/** Worktree absolute path → its target entry. */
export type TargetMap = Record<string, TargetEntry>;

/** Absolute path of the target-branch persistence file. */
export function worktreeTargetsFile(): string {
  return process.env.MAKIT_WORKTREE_TARGETS_FILE ?? join(makitHome(), "worktree-targets.json");
}

/**
 * Read the persisted map. A missing, unreadable or malformed file yields `{}`.
 *
 * Entries are validated individually: one bad value skips only that key rather
 * than discarding every other worktree's target (the same isolation
 * `loadProjects` learned to apply). An empty-string branch is treated as absent
 * so a truncated write cannot resolve to a ref named "".
 */
export function loadTargets(file: string): TargetMap {
  try {
    if (!existsSync(file)) return {};
    const parsed = JSON.parse(readFileSync(file, "utf8")) as unknown;
    if (typeof parsed !== "object" || parsed === null) return {};
    const raw = (parsed as { targets?: unknown }).targets;
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) return {};
    const out: TargetMap = {};
    for (const [path, value] of Object.entries(raw as Record<string, unknown>)) {
      if (typeof path !== "string" || !path) continue;
      // v1 of this file stored a bare branch string. Read it so upgrading does
      // not silently drop every worktree's target.
      if (typeof value === "string") {
        if (value) out[path] = { target: value };
        continue;
      }
      if (typeof value !== "object" || value === null) continue;
      const { target, retargetedFrom } = value as Partial<TargetEntry>;
      if (typeof target !== "string" || !target) continue;
      out[path] =
        typeof retargetedFrom === "string" && retargetedFrom
          ? { target, retargetedFrom }
          : { target };
    }
    return out;
  } catch (e) {
    log.warn(`[makit] failed to read worktree targets ${file}: ${(e as Error).message}`);
    return {};
  }
}

/**
 * Persist the map atomically: write a sibling temp file, then `rename` it over
 * the destination. `rename` within a directory is atomic on POSIX, so a reader
 * only ever sees the old file or the new one — never a half-written one.
 *
 * Never throws — a broken disk must not crash a background snapshot repair. It
 * does, however, RETURN whether the write landed: an interactive command
 * (`worktree.setTarget`) needs to tell the user the truth rather than ack a
 * success the next snapshot will contradict. A failed write is logged and the
 * temp file cleaned up so a broken disk does not leave litter beside the store.
 */
export function saveTargets(file: string, targets: TargetMap): boolean {
  const tmp = `${file}.tmp`;
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(tmp, JSON.stringify({ targets }, null, 2) + "\n");
    renameSync(tmp, file);
    return true;
  } catch (e) {
    log.warn(`[makit] failed to write worktree targets ${file}: ${(e as Error).message}`);
    try {
      if (existsSync(tmp)) unlinkSync(tmp);
    } catch {
      // Best-effort cleanup; the write already failed and we must not throw.
    }
    return false;
  }
}

/** The target branch recorded for `worktreePath`, or null. */
export function targetOf(file: string, worktreePath: string): string | null {
  return loadTargets(file)[worktreePath]?.target ?? null;
}

/**
 * Record `branch` as the target for `worktreePath`, leaving other keys alone.
 *
 * Omitting `retargetedFrom` CLEARS any existing note, which is what an explicit
 * user choice should do: they have taken ownership of the value, so there is no
 * longer an automatic change to announce.
 *
 * Returns whether the write persisted, so an interactive caller can surface a
 * failure instead of falsely acking success.
 */
export function putTarget(
  file: string,
  worktreePath: string,
  branch: string,
  opts: { retargetedFrom?: string } = {},
): boolean {
  const all = loadTargets(file);
  all[worktreePath] = opts.retargetedFrom
    ? { target: branch, retargetedFrom: opts.retargetedFrom }
    : { target: branch };
  return saveTargets(file, all);
}

/**
 * Follow a branch rename: every worktree that landed in `oldName` now lands in
 * `newName`. Returns how many moved.
 *
 * Without this, renaming a branch leaves every worktree aiming at it pointing at
 * a name that no longer resolves — the diff becomes unmeasurable and the
 * worktree looks broken, for a rename that was none of its business. Any
 * `retargetedFrom` note is preserved: the rename does not change the fact that we
 * had already moved that worktree once.
 *
 * Writes only when something changed, so a rename of an untargeted branch does
 * not churn the file.
 *
 * [scope], when given, restricts the rewrite to those worktree paths. The store
 * is GLOBAL across every project, and branch names are not unique across repos,
 * so a caller renaming a branch in one repo must pass its own worktree paths or
 * it would silently rewrite a same-named target in an unrelated repo.
 */
export function renameTargetBranch(
  file: string,
  oldName: string,
  newName: string,
  scope?: ReadonlySet<string>,
): number {
  if (!oldName || !newName || oldName === newName) return 0;
  const all = loadTargets(file);
  let moved = 0;
  for (const [path, entry] of Object.entries(all)) {
    if (entry.target !== oldName) continue;
    if (scope && !scope.has(path)) continue;
    all[path] = { ...entry, target: newName };
    moved++;
  }
  if (moved > 0) saveTargets(file, all);
  return moved;
}

/** Forget `worktreePath`'s target. A key that is already absent is a no-op. */
export function clearTarget(file: string, worktreePath: string): void {
  const all = loadTargets(file);
  if (!(worktreePath in all)) return;
  delete all[worktreePath];
  saveTargets(file, all);
}

/**
 * Drop entries for worktrees that are no longer live, and return how many went.
 *
 * This is not housekeeping — it is correctness. Worktree paths are derived
 * deterministically from repo + name, so `rm`-ing a worktree and creating
 * another with the same name reuses the path; a surviving entry would hand the
 * new worktree the old one's merge destination.
 *
 * Writes only when something actually changed, so calling it on every snapshot
 * does not churn the file (or its mtime) for no reason.
 */
export function pruneTargets(file: string, livePaths: readonly string[]): number {
  const all = loadTargets(file);
  const live = new Set(livePaths);
  const stale = Object.keys(all).filter((p) => !live.has(p));
  if (stale.length === 0) return 0;
  for (const p of stale) delete all[p];
  saveTargets(file, all);
  return stale.length;
}
