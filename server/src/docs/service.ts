/**
 * makit — SPEC-46 D11: the docs subsystem's one stateful piece.
 *
 * Mirrors {@link PortsService}'s watch-gated, ref-counted lifecycle, with one
 * deliberate difference: there is **no polling loop**. The tree already has a
 * watcher (`worktree_watcher.ts`), so re-index is driven by `onWorktreeChange`
 * with a 400 ms debounce — nothing is walked while no client watches, and a
 * burst of fs events collapses into a single walk. The last snapshot is cached
 * and handed to a freshly-arrived watcher on the 0→1 edge (the metrics-history
 * trick), so its list paints immediately.
 *
 * Everything is injected (the worktree source, the scan, the merge-base diff,
 * the grant store, the reach probe, the clock and the timer) so the whole file
 * is testable with fakes — no fs walk and no `git` spawn in a unit test.
 */

import type { DocsSnapshotDTO, DocDTO, DocGrantDTO } from "../protocol.js";
import { scanWorktree, type WorktreeScan } from "./scan.js";
import { changedPaths as defaultChangedPaths, type Exec } from "./changed.js";
import { readDocText, type DocReadResult } from "./read.js";
import { openDocOnHost, type OpenResult } from "./open.js";
import { publishDoc, type DocReach, type PublishResult } from "./publish.js";
import type { DocGrantStore } from "./grants.js";

/** Trailing debounce on a worktree change before re-indexing. */
export const DOCS_DEBOUNCE_MS = 400;

/** One worktree to index, plus the two branches the merge-base diff needs (D5). */
export interface DocWorktree {
  worktreePath: string;
  baseBranch: string | null;
  currentBranch: string | null;
}

export interface DocsServiceDeps {
  /** Worktrees to index, from the cached repos snapshot (no git per scan). */
  listWorktrees: () => DocWorktree[];
  /** `run`-shaped exec for the merge-base `changed` diff (D5). */
  exec: Exec;
  grants: DocGrantStore;
  /** Establish/reuse a verified reachable origin for the doc listener (D10/D15). */
  reach: () => Promise<DocReach | null>;
  /**
   * Called after anything that can leave the grant set empty (a revoke, or a
   * list that reaped the last expired grant). `server.ts` uses it to release the
   * lazily-bound doc port, so an expiry frees it without a timer (D10 rev 2).
   */
  onGrantsChanged?: () => void;
  onSnapshot: (snapshot: DocsSnapshotDTO) => void;
  now: () => number;
  /** One-shot `setTimeout`-shaped: the debounce, NOT a repeating cadence. */
  setTimer: (fn: () => void, ms: number) => unknown;
  clearTimer: (handle: unknown) => void;
  /** Injected for tests; default {@link scanWorktree}. */
  scan?: (worktreePath: string) => Promise<WorktreeScan>;
  /** Injected for tests; default {@link defaultChangedPaths}. */
  changedPaths?: (
    worktreePath: string,
    baseBranch: string | null,
    currentBranch: string | null,
    exec: Exec,
  ) => Promise<ReadonlySet<string> | undefined>;
}

export interface DocsCommandPort {
  /**
   * True when `worktreePath` is one the index actually reported. The scoping
   * boundary for client-supplied paths: a client may only name a worktree the
   * snapshot listed it, never an arbitrary directory on the host.
   */
  isIndexedWorktree(worktreePath: string): boolean;
  read(worktreePath: string, relPath: string): DocReadResult;
  publish(worktreePath: string, relPath: string, ownerDeviceId?: string): Promise<PublishResult>;
  /**
   * Open the doc on the machine holding it (D8 rev 2). Async and
   * reason-carrying, because the failure has to be *stated*: the opener can be
   * missing, the platform unknown, or the path refused by D2, and "could not
   * open document" tells the user none of that.
   *
   * The **local-client gate lives in the command layer**, which is the only
   * place that knows the connection.
   */
  open(worktreePath: string, relPath: string): Promise<OpenResult>;
  /**
   * Revoke a grant the caller owns. Foreign/unknown ids are a silent no-op so a
   * caller can neither revoke another device's share nor probe for its id.
   */
  unpublish(grantId: string, ownerDeviceId?: string): boolean;
  /** The caller's own live grants — never another device's. */
  grants(ownerDeviceId?: string): DocGrantDTO[];
}

export class DocsService implements DocsCommandPort {
  private readonly deps: DocsServiceDeps;
  private readonly scan: (worktreePath: string) => Promise<WorktreeScan>;
  private readonly changedPaths: DocsServiceDeps["changedPaths"] & object;

  private watchers = 0;
  /** The pending debounce, or null when none is armed. There is no cadence timer. */
  private handle: unknown = null;
  /** True while a walk is in flight — a re-index that overlaps one is skipped. */
  private scanning = false;
  /** A change arrived mid-walk: re-run once, after the current walk finishes. */
  private rescanQueued = false;
  private cached: DocsSnapshotDTO | undefined;

  constructor(deps: DocsServiceDeps) {
    this.deps = deps;
    this.scan = deps.scan ?? scanWorktree;
    this.changedPaths = deps.changedPaths ?? defaultChangedPaths;
  }

  cachedSnapshot(): DocsSnapshotDTO | undefined {
    return this.cached;
  }

  /**
   * Set the number of watching clients. The 0→1 edge runs one immediate walk
   * (a freshly-mounted screen paints within one scan, not on the next fs
   * event); the 1→0 edge cancels any pending debounce and does no work.
   */
  setWatchers(n: number): void {
    const prev = this.watchers;
    this.watchers = n;
    if (prev === 0 && n > 0) void this.runScan();
    else if (prev > 0 && n === 0) this.disarm();
  }

  /**
   * The tree changed on disk. While watched, (re)arm the trailing debounce so a
   * burst of git churn collapses into one walk; while unwatched, do nothing —
   * the index is never built ambiently.
   */
  onWorktreeChange(): void {
    if (this.watchers === 0) return;
    this.disarm();
    this.handle = this.deps.setTimer(() => {
      this.handle = null;
      void this.runScan();
    }, DOCS_DEBOUNCE_MS);
  }

  /** Cancel any pending debounce (shutdown, or the last watcher leaving). */
  stop(): void {
    this.disarm();
  }

  private disarm(): void {
    if (this.handle !== null) {
      this.deps.clearTimer(this.handle);
      this.handle = null;
    }
  }

  /**
   * One walk at a time. A change that arrives mid-walk is not dropped: it sets
   * `rescanQueued` and a single follow-up walk runs once the current one
   * finishes (nothing else re-arms the timer — there is no polling loop, D11).
   * Publishes nothing if the last watcher left mid-walk.
   */
  private async runScan(): Promise<void> {
    if (this.scanning) {
      // A worktree change fired the debounce while a walk was in flight. Record
      // it and re-run once at the end — without this the change is lost and the
      // index stays stale until the user happens to touch the tree again.
      this.rescanQueued = true;
      return;
    }
    this.scanning = true;
    try {
      const snapshot = await this.doScan();
      if (this.watchers === 0) return; // last watcher left mid-walk → publish nothing
      this.cached = snapshot;
      this.deps.onSnapshot(snapshot);
    } catch (err) {
      // Every caller is `void runScan()` (a watcher edge, a debounce firing), so
      // an escaping rejection would be an unhandled one that kills nothing
      // visibly and reports nothing. Publish the failure as a scan that ran and
      // found nothing, which is what `scanOk:false` exists to say.
      const snapshot = {
        docs: [],
        scannedAt: this.deps.now(),
        scanOk: false,
        scanError: (err as Error).message,
      };
      // Same watcher guard as the success path: a failure after the last watcher
      // left must not overwrite a good cached snapshot with an error the next
      // client would then be handed on its 0→1 edge.
      if (this.watchers === 0) return;
      this.cached = snapshot;
      this.deps.onSnapshot(snapshot);
    } finally {
      this.scanning = false;
      if (this.rescanQueued) {
        this.rescanQueued = false;
        if (this.watchers > 0) void this.runScan();
      }
    }
  }

  /**
   * Walk every worktree, enrich each doc with `changed` from its merge base, and
   * concatenate — grouped by worktree, each group already mtime-descending. A
   * worktree whose walk did not run pulls the whole snapshot's `scanOk` false
   * (the walk-ran discipline), but never fails the others.
   *
   * Worktrees are independent, and per worktree the scan and the merge-base diff
   * are independent, so both fan out concurrently — the walk costs one round
   * instead of the sum of 2N sequential operations, shrinking the window in
   * which a mid-walk change has to be queued. The grouped, `listWorktrees`-order
   * output is preserved by aggregating the settled results in their original
   * order.
   */
  private async doScan(): Promise<DocsSnapshotDTO> {
    const worktrees = this.deps.listWorktrees();
    const results = await Promise.all(
      worktrees.map(async (wt) => {
        const [scan, changed] = await Promise.all([
          this.scan(wt.worktreePath),
          // `changed` is best-effort: an undetermined result leaves the flag
          // ABSENT (D14), never false-for-all.
          this.changedPaths(wt.worktreePath, wt.baseBranch, wt.currentBranch, this.deps.exec),
        ]);
        return { scan, changed };
      }),
    );

    const docs: DocDTO[] = [];
    let scanOk = true;
    let scanError: string | undefined;

    for (const { scan, changed } of results) {
      if (!scan.scanOk) {
        scanOk = false;
        scanError ??= scan.scanError;
      }
      for (const doc of scan.docs) {
        if (changed !== undefined) doc.changed = changed.has(doc.relPath);
        docs.push(doc);
      }
    }

    const snapshot: DocsSnapshotDTO = { docs, scannedAt: this.deps.now(), scanOk };
    if (scanError !== undefined) snapshot.scanError = scanError;
    return snapshot;
  }

  // -------- command surface (docs.read / publish / unpublish / grants) --------

  isIndexedWorktree(worktreePath: string): boolean {
    return this.deps.listWorktrees().some((wt) => wt.worktreePath === worktreePath);
  }

  read(worktreePath: string, relPath: string): DocReadResult {
    return readDocText(worktreePath, relPath);
  }

  publish(worktreePath: string, relPath: string, ownerDeviceId?: string): Promise<PublishResult> {
    return publishDoc(
      { worktreePath, relPath, ownerDeviceId },
      { grants: this.deps.grants, reach: this.deps.reach },
    );
  }

  open(worktreePath: string, relPath: string): Promise<OpenResult> {
    // `openDocOnHost` owns the D2 resolve, the per-platform opener and the
    // argv-not-shell discipline, and is tested for all three.
    return openDocOnHost(worktreePath, relPath);
  }

  unpublish(grantId: string, ownerDeviceId?: string): boolean {
    const removed = this.deps.grants.revoke(grantId, ownerDeviceId);
    this.deps.onGrantsChanged?.();
    return removed;
  }

  grants(ownerDeviceId?: string): DocGrantDTO[] {
    // `listOwnedBy()` reaps expired/idle grants on the way through, so this is
    // also the moment a TTL expiry can leave the set empty.
    const live = this.deps.grants.listOwnedBy(ownerDeviceId);
    this.deps.onGrantsChanged?.();
    return live;
  }
}
