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

import { watch, existsSync, readFileSync, statSync, type FSWatcher } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

/**
 * Resolve the git dir and the directory where git records this repo's linked
 * worktrees. For a PRIMARY checkout, `<repo>/.git` is a directory and worktrees
 * live under `<repo>/.git/worktrees`. For a *linked worktree* checkout, though,
 * `<repo>/.git` is a FILE (`gitdir: <common>/.git/worktrees/<name>`) and the
 * shared worktrees dir is that target's parent — `<repo>/.git/worktrees` does
 * NOT exist. Watching the wrong path means a `git worktree add` run from a
 * linked-worktree project never surfaces in the app until the next reconnect.
 */
function resolveGitPaths(repoPath: string): { gitDir: string; worktreesDir: string } {
  // Walk up to the nearest ancestor holding a `.git` entry — a registered
  // project path may be a SUBDIRECTORY of the checkout (e.g. a monorepo
  // package like `<repo>/server`), where `.git` lives higher up.
  let dir = resolve(repoPath);
  for (;;) {
    const dotGit = join(dir, ".git");
    try {
      const st = statSync(dotGit);
      if (st.isDirectory()) {
        // Primary checkout: worktrees live under `<repo>/.git/worktrees`.
        return { gitDir: dotGit, worktreesDir: join(dotGit, "worktrees") };
      }
      if (st.isFile()) {
        // Linked worktree: `.git` is a file `gitdir: <common>/.git/worktrees/<name>`,
        // so the shared worktrees dir is that target's parent. (Submodule
        // gitdirs are not under a `worktrees/` segment — fall back to
        // `<target>/worktrees`.)
        const m = /^gitdir:\s*(.+?)\s*$/m.exec(readFileSync(dotGit, "utf8"));
        if (m) {
          const target = isAbsolute(m[1]) ? m[1] : resolve(dir, m[1]);
          if (basename(dirname(target)) === "worktrees") {
            const worktreesDir = dirname(target);
            return { gitDir: dirname(worktreesDir), worktreesDir };
          }
          return { gitDir: target, worktreesDir: join(target, "worktrees") };
        }
      }
    } catch {
      // No `.git` here (or unreadable) — keep walking up.
    }
    const parent = dirname(dir);
    if (parent === dir) break; // reached the filesystem root
    dir = parent;
  }
  // Not a git repo anywhere up the tree — default (the watch may never fire).
  const dotGit = join(repoPath, ".git");
  return { gitDir: dotGit, worktreesDir: join(dotGit, "worktrees") };
}

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

  // `fs.watch` returns an EventEmitter that emits `'error'` ASYNCHRONOUSLY
  // (e.g. the watched dir is deleted at runtime). An unhandled `'error'`
  // crashes the whole process, so every watcher must attach a handler — a
  // plain try/catch only covers synchronous setup failures.
  const safeWatch = (
    target: string,
    onEvent: (filename: string | null) => void,
    onError: () => void,
  ): FSWatcher | undefined => {
    try {
      const w = watch(target, { persistent: false }, (_evt, filename) =>
        onEvent(filename === null ? null : filename.toString()),
      );
      w.on("error", () => {
        try {
          w.close();
        } catch {
          /* already closed */
        }
        onError();
      });
      return w;
    } catch {
      // Target missing, or `.git` is a file (linked worktree / submodule).
      return undefined;
    }
  };

  const arm = (repoPath: string): RepoWatch => {
    const { gitDir, worktreesDir } = resolveGitPaths(repoPath);
    const rw: RepoWatch = {};

    const syncInner = (): void => {
      if (existsSync(worktreesDir)) {
        rw.inner ??= safeWatch(
          worktreesDir,
          () => fire(),
          () => {
            // Dir vanished (last worktree removed): drop the watch so the
            // `.git` watcher can re-attach if it reappears, and re-scan.
            rw.inner = undefined;
            fire();
          },
        );
      } else if (rw.inner) {
        rw.inner.close();
        rw.inner = undefined;
      }
    };

    rw.git = safeWatch(
      gitDir,
      (filename) => {
        // Only the `worktrees` entry matters; ignore git's other churn
        // (index.lock, HEAD, refs, …). A null filename (some platforms) is
        // treated as "unknown" and re-evaluated.
        if (filename !== null && filename !== "worktrees") return;
        syncInner();
        fire();
      },
      () => {
        rw.git = undefined;
      },
    );

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
