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

import { execFileSync } from "node:child_process";
import {
  watch,
  existsSync,
  readdirSync,
  realpathSync,
  statSync,
  type Dirent,
  type FSWatcher,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

/**
 * Ask Git for the common directory where it records linked worktrees. This is
 * `<repo>/.git` for a primary checkout, the primary repo's git dir for a linked
 * worktree (regardless of the checkout's location), and the submodule's module
 * git dir for a submodule checkout.
 */
function resolveGitPaths(repoPath: string): {
  gitDir: string;
  worktreesDir: string;
  headsDir: string;
} {
  const unresolvedGitDir = join(repoPath, ".git");
  const unresolved = {
    gitDir: unresolvedGitDir,
    worktreesDir: join(unresolvedGitDir, "worktrees"),
    headsDir: join(unresolvedGitDir, "refs", "heads"),
  };

  try {
    const [topLevel, commonDir] = execFileSync(
      "git",
      ["-C", repoPath, "rev-parse", "--show-toplevel", "--git-common-dir"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    )
      .trim()
      .split(/\r?\n/);
    if (!topLevel || !commonDir) return unresolved;

    // Git treats every descendant of a home/root-level checkout as belonging
    // to it. Do not let an unrelated registered project inherit such a broad
    // ancestor watcher; direct registration of that checkout remains valid.
    if (realpathSync(repoPath) !== topLevel) {
      const topParent = dirname(topLevel);
      if (
        topLevel === resolve(homedir()) ||
        topParent === topLevel ||
        statSync(topLevel).dev !== statSync(topParent).dev
      ) {
        return unresolved;
      }
    }

    const gitDir = resolve(repoPath, commonDir);
    return {
      gitDir,
      worktreesDir: join(gitDir, "worktrees"),
      headsDir: join(gitDir, "refs", "heads"),
    };
  } catch {
    // Missing/non-repo paths and git lookup failures remain best-effort no-ops.
    return unresolved;
  }
}

export interface WorktreeWatcher {
  /** Re-arm to watch exactly [repoPaths], diffed against the current set. */
  sync(repoPaths: string[]): void;
  /** Stop and drop all watchers. */
  close(): void;
  /**
   * Live watcher count. The per-directory fallback re-walks its tree on every
   * event to pick up a new branch namespace, so this is the seam that holds that
   * re-walk to *adding* watchers rather than duplicating them.
   */
  watcherCount(): number;
}

interface RepoWatch {
  /** Watch on `<repo>/.git` — tracks the `worktrees` dir lifecycle. */
  git?: FSWatcher;
  /** Watch on `<repo>/.git/worktrees` — tracks worktree add/remove. */
  inner?: FSWatcher;
  /**
   * Watches on `<repo>/.git/refs/heads`, keyed by the directory each one covers —
   * normally just the one recursive watch on `heads` itself.
   *
   * Git stores `feature/foo` as a file in a *nested* directory, and `fs.watch`
   * without `recursive: true` reports nothing for nested children on Linux or
   * macOS — so a flat watch misses every slashed branch, which is most of them.
   * When the platform refuses a recursive watch this holds one watcher per
   * directory instead.
   *
   * Keyed rather than listed because that fallback re-walks the tree on every
   * event (a new namespace needs its own watcher): appending, it duplicated every
   * directory it had already covered, and each duplicate re-walked in turn.
   */
  heads: Map<string, FSWatcher>;
}

/**
 * Create a debounced worktree watcher. Call [WorktreeWatcher.sync] with the
 * current repo paths (idempotent) and [WorktreeWatcher.close] on shutdown.
 */
export function watchWorktrees(
  onChange: () => void,
  opts: { debounceMs?: number; recursive?: boolean } = {},
): WorktreeWatcher {
  const debounceMs = opts.debounceMs ?? 300;
  // Off only in the test that exercises the per-directory fallback: it exists for
  // a platform that refuses `recursive`, which cannot be reproduced by asking for
  // one and hoping it fails.
  const allowRecursive = opts.recursive ?? true;
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
    options: { recursive?: boolean } = {},
  ): FSWatcher | undefined => {
    try {
      const w = watch(target, { persistent: false, ...options }, (_evt, filename) =>
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

  /**
   * Watch [dir] and every directory under it, one watcher each. The fallback for
   * platforms that refuse `recursive: true`; also re-run when a namespace
   * directory appears, since a new one needs its own watcher.
   *
   * Bounded by the shape of the data: branch namespaces are a handful of shallow
   * directories, not a source tree.
   */
  const watchTree = (
    dir: string,
    out: Map<string, FSWatcher>,
    onEvent: () => void,
  ): void => {
    if (!out.has(dir)) {
      const w = safeWatch(
        dir,
        () => {
          // A new namespace directory may have just appeared (`git branch a/b/c`),
          // so re-arm before reporting. Directories already covered are skipped,
          // which is what keeps a re-walk from doubling the set.
          watchTree(dir, out, onEvent);
          onEvent();
        },
        () => {
          // Gone: forget it, so a later walk re-attaches if it comes back.
          out.delete(dir);
        },
      );
      if (w) out.set(dir, w);
    }
    let entries: Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return; // missing or unreadable: nothing to descend into
    }
    for (const e of entries) {
      if (e.isDirectory()) watchTree(join(dir, e.name), out, onEvent);
    }
  };

  const arm = (repoPath: string): RepoWatch => {
    const { gitDir, worktreesDir, headsDir } = resolveGitPaths(repoPath);
    const rw: RepoWatch = { heads: new Map() };

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
        // `worktrees` re-arms the inner watch; `HEAD` moves when the primary
        // checkout switches branch or detaches. Everything else here is git's own
        // churn (`index`, `index.lock`, `COMMIT_EDITMSG`, …) and would rebuild the
        // snapshot — a full git pass per worktree — many times per turn.
        if (filename !== null && filename !== "worktrees" && filename !== "HEAD") {
          return;
        }
        syncInner();
        fire();
      },
      () => {
        rw.git = undefined;
      },
    );

    // Commits are what the snapshot's `uncommittedFiles`/`aheadCount` react to,
    // and a commit moves a branch ref. Those refs live in the **common** git dir
    // whichever worktree moved them, so this one watch covers every worktree of
    // the repo — including the linked ones agents actually work in. Without it the
    // only triggers were connect/spawn/kill/pull-to-refresh, so the composer's bar
    // kept asserting a file count from whenever the client last connected.
    //
    // Recursive, because `feature/foo` is a file in a nested directory and a flat
    // watch reports nothing for those — which is most branches. Node supports
    // `recursive` on macOS, Windows and Linux (≥ 20.13; this package requires
    // ≥ 22.13); anywhere it is refused, fall back to one watcher per directory.
    const recursive = allowRecursive
      ? safeWatch(headsDir, () => fire(), () => {}, { recursive: true })
      : undefined;
    if (recursive) rw.heads.set(headsDir, recursive);
    else watchTree(headsDir, rw.heads, fire);

    syncInner();
    return rw;
  };

  const closeRepo = (rw: RepoWatch): void => {
    rw.git?.close();
    rw.inner?.close();
    for (const w of rw.heads.values()) w.close();
    rw.heads.clear();
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
    watcherCount(): number {
      let n = 0;
      for (const rw of repos.values()) {
        n += (rw.git ? 1 : 0) + (rw.inner ? 1 : 0) + rw.heads.size;
      }
      return n;
    },
  };
}
