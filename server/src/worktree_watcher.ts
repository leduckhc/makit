/**
 * Filesystem watcher that fires when a repo's git worktrees change on disk —
 * e.g. a worktree created or removed via the CLI, outside makit. The server
 * has no other trigger to re-scan worktrees between client (re)connections, so
 * without this a `git worktree add` only surfaces in the app on the next
 * reconnect/auth. Git records each linked worktree under `<repo>/.git/worktrees`,
 * so watching that directory lets the server push a fresh `repos.snapshot`
 * promptly.
 *
 * Design:
 *   - The `.git/worktrees` dir only exists once a repo has ≥1 linked worktree,
 *     so we also watch `.git` itself and (re)attach the inner watch when the
 *     `worktrees` dir appears (first worktree) or drops (last one removed).
 *   - Best-effort: every `fs.watch` is guarded (a repo may not be a git repo,
 *     or `.git` may be a file for a linked worktree/submodule) and errors are
 *     swallowed rather than crashing the server.
 *   - Debounced (trailing): git churns these paths during normal operations,
 *     so bursts collapse into a single `onChange`.
 */

import { watch, existsSync, type FSWatcher } from "node:fs";
import { join } from "node:path";

export interface WorktreeWatcher {
  /** Re-arm to watch exactly [repoPaths], diffed against the current set. */
  sync(repoPaths: string[]): void;
  /** Stop and drop all watchers. */
  close(): void;
}

interface RepoWatch {
  /** Watch on `<repo>/.git` — tracks the `worktrees` dir lifecycle. */
  git?: FSWatcher;
  /** Watch on `<repo>/.git/worktrees` — tracks worktree add/remove. */
  inner?: FSWatcher;
}

/**
 * Create a debounced worktree watcher. Call [WorktreeWatcher.sync] with the
 * current repo paths (idempotent) and [WorktreeWatcher.close] on shutdown.
 */
export function watchWorktrees(
  onChange: () => void,
  opts: { debounceMs?: number } = {},
): WorktreeWatcher {
  const debounceMs = opts.debounceMs ?? 300;
  const repos = new Map<string, RepoWatch>();
  let timer: ReturnType<typeof setTimeout> | undefined;

  const fire = (): void => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = undefined;
      onChange();
    }, debounceMs);
    // Don't keep the process alive just for a pending debounce.
    timer.unref?.();
  };

  const arm = (repoPath: string): RepoWatch => {
    const gitDir = join(repoPath, ".git");
    const worktreesDir = join(gitDir, "worktrees");
    const rw: RepoWatch = {};

    const syncInner = (): void => {
      if (existsSync(worktreesDir)) {
        if (!rw.inner) {
          try {
            rw.inner = watch(worktreesDir, { persistent: false }, () => fire());
          } catch {
            /* best-effort */
          }
        }
      } else if (rw.inner) {
        rw.inner.close();
        rw.inner = undefined;
      }
    };

    try {
      rw.git = watch(gitDir, { persistent: false }, (_evt, filename) => {
        // Only the `worktrees` entry matters; ignore git's other churn
        // (index.lock, HEAD, refs, …). A null filename (some platforms) is
        // treated as "unknown" and re-evaluated.
        if (filename !== null && filename.toString() !== "worktrees") return;
        syncInner();
        fire();
      });
    } catch {
      // `.git` missing or a file (linked worktree / submodule) — skip.
    }

    syncInner();
    return rw;
  };

  const closeRepo = (rw: RepoWatch): void => {
    rw.git?.close();
    rw.inner?.close();
  };

  return {
    sync(repoPaths: string[]): void {
      const next = new Set(repoPaths);
      for (const [path, rw] of repos) {
        if (!next.has(path)) {
          closeRepo(rw);
          repos.delete(path);
        }
      }
      for (const path of next) {
        if (!repos.has(path)) repos.set(path, arm(path));
      }
    },
    close(): void {
      if (timer) clearTimeout(timer);
      timer = undefined;
      for (const rw of repos.values()) closeRepo(rw);
      repos.clear();
    },
  };
}
