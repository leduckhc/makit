import assert from "node:assert/strict";
import { test } from "node:test";

import { DocsService, DOCS_DEBOUNCE_MS, type DocWorktree } from "./service.js";
import { DocGrantStore } from "./grants.js";
import type { WorktreeScan } from "./scan.js";
import type { DocsSnapshotDTO, DocDTO } from "../protocol.js";
import type { Exec } from "./changed.js";

function docOf(worktreePath: string, relPath: string, mtime = 1): DocDTO {
  return {
    key: `${worktreePath}:${relPath}`,
    relPath,
    title: relPath,
    kind: relPath.endsWith(".html") ? "html" : "md",
    bytes: 10,
    modifiedAt: mtime,
    worktreePath,
  };
}

function makeService(overrides: {
  listWorktrees?: () => DocWorktree[];
  scan?: (worktreePath: string) => Promise<WorktreeScan>;
  changed?: () => Promise<ReadonlySet<string> | undefined>;
  exec?: Exec;
  onGrantsChanged?: () => void;
} = {}) {
  const snapshots: DocsSnapshotDTO[] = [];
  const timers: { fn: () => void; cancelled: boolean }[] = [];
  let clears = 0;
  const grants = new DocGrantStore();

  const defaultScan = async (worktreePath: string): Promise<WorktreeScan> => ({
    docs: [docOf(worktreePath, "spec.md")],
    scanOk: true,
  });

  const service = new DocsService({
    listWorktrees: overrides.listWorktrees ?? (() => [{ worktreePath: "/wt", baseBranch: "main", currentBranch: "feat" }]),
    exec: overrides.exec ?? (async () => ({ code: 0, stdout: "", stderr: "" })),
    grants,
    reach: async () => ({ origin: "http://100.92.14.7:53187", reach: "tailnet" }),
    scan: overrides.scan ?? defaultScan,
    changedPaths: overrides.changed ?? (async () => new Set<string>()),
    onSnapshot: (s) => snapshots.push(s),
    onGrantsChanged: overrides.onGrantsChanged,
    now: () => 1_700_000_000_000,
    setTimer: (fn) => {
      const h = { fn, cancelled: false };
      timers.push(h);
      return h;
    },
    clearTimer: (h) => {
      (h as { cancelled: boolean }).cancelled = true;
      clears++;
    },
  });

  return {
    service,
    snapshots,
    grants,
    armed: () => timers.filter((t) => !t.cancelled).length,
    fire: () => {
      for (const t of timers) if (!t.cancelled) { t.cancelled = true; t.fn(); }
    },
    cleared: () => clears,
  };
}

const flush = () => new Promise((r) => setImmediate(r));

// t29: `runScan` guards against overlap, but a change that arrives mid-walk must
// not be lost — nothing else re-arms the timer (no polling loop, D11), so the
// service must remember the overlap and re-run exactly once when the walk ends.
test("a worktree change during an in-flight walk re-runs once the walk finishes", async () => {
  const gates: Array<() => void> = [];
  let scanCalls = 0;
  const h = makeService({
    scan: async (worktreePath): Promise<WorktreeScan> => {
      scanCalls++;
      await new Promise<void>((r) => gates.push(r));
      return { docs: [docOf(worktreePath, "spec.md")], scanOk: true };
    },
  });

  h.service.setWatchers(1); // 0→1 starts an immediate walk that now blocks
  await flush();
  assert.equal(scanCalls, 1, "the first walk started");

  // A change lands mid-walk: arm + fire the debounce so it re-enters runScan.
  h.service.onWorktreeChange();
  h.fire();
  await flush();
  assert.equal(scanCalls, 1, "the overlapping change must not start a concurrent walk");

  gates.shift()!(); // let the first walk finish
  await flush();
  assert.equal(scanCalls, 2, "the queued change must drive exactly one follow-up walk");

  gates.shift()!(); // let the follow-up finish
  await flush();
  assert.equal(scanCalls, 2, "no extra walk beyond the single queued re-run");
  assert.equal(h.snapshots.length, 2, "both walks published");
});

// t30: the successful path already skips caching when the last watcher left
// mid-walk; the failure path must apply the same guard, or a walk that fails
// after everyone left overwrites a good cache with scanOk:false and paints a
// stale error to the next client that starts watching.
test("a walk that fails after the last watcher leaves does not overwrite the good cache", async () => {
  const gates: Array<() => void> = [];
  let scanCalls = 0;
  const h = makeService({
    scan: async (worktreePath): Promise<WorktreeScan> => {
      scanCalls++;
      if (scanCalls === 1) return { docs: [docOf(worktreePath, "spec.md")], scanOk: true };
      await new Promise<void>((r) => gates.push(r));
      throw new Error("boom");
    },
  });

  h.service.setWatchers(1); // first walk succeeds and caches a good snapshot
  await flush();
  assert.equal(h.service.cachedSnapshot()?.scanOk, true);

  h.service.onWorktreeChange();
  h.fire(); // starts the second walk, which blocks then throws
  await flush();
  h.service.setWatchers(0); // last watcher leaves mid-walk
  gates.shift()!();
  await flush();

  assert.equal(
    h.service.cachedSnapshot()?.scanOk,
    true,
    "a failure with no watchers must keep the last good cache",
  );
});

test("no watchers: a worktree change walks nothing (no timer, no scan)", async () => {
  const h = makeService();
  h.service.onWorktreeChange();
  await flush();
  assert.equal(h.armed(), 0, "a debounce was armed while unwatched");
  assert.equal(h.snapshots.length, 0);
});

test("0→1 runs one immediate scan and publishes it (no polling)", async () => {
  const h = makeService();
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.snapshots.length, 1);
  assert.equal(h.snapshots[0]!.docs[0]!.relPath, "spec.md");
  assert.equal(h.snapshots[0]!.scanOk, true);
  assert.equal(h.armed(), 0, "the 0→1 scan is immediate, not a timer");
});

test("a worktree change while watched arms a 400ms debounce that re-indexes on fire", async () => {
  const h = makeService();
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.snapshots.length, 1);
  h.service.onWorktreeChange();
  assert.equal(h.armed(), 1, "a debounce should be armed");
  assert.equal(DOCS_DEBOUNCE_MS, 400);
  h.fire();
  await flush();
  assert.equal(h.snapshots.length, 2, "the debounce fired a re-index");
});

test("a burst of worktree changes collapses into a single re-index", async () => {
  const h = makeService();
  h.service.setWatchers(1);
  await flush();
  h.service.onWorktreeChange();
  h.service.onWorktreeChange();
  h.service.onWorktreeChange();
  assert.ok(h.cleared() >= 2, "each new change cancels the pending debounce");
  assert.equal(h.armed(), 1, "exactly one debounce is pending");
});

test("1→0 cancels a pending debounce", async () => {
  const h = makeService();
  h.service.setWatchers(1);
  await flush();
  h.service.onWorktreeChange();
  assert.equal(h.armed(), 1);
  h.service.setWatchers(0);
  assert.equal(h.armed(), 0, "the pending debounce was cancelled on the last watcher leaving");
});

test("enriches changed from the merge base: true when in the set, false when not, absent when undetermined", async () => {
  const wt = { worktreePath: "/wt", baseBranch: "main", currentBranch: "feat" };
  const scan = async (worktreePath: string): Promise<WorktreeScan> => ({
    docs: [docOf(worktreePath, "a.md"), docOf(worktreePath, "b.md")],
    scanOk: true,
  });

  const inSet = makeService({ listWorktrees: () => [wt], scan, changed: async () => new Set(["a.md"]) });
  inSet.service.setWatchers(1);
  await flush();
  const docs = inSet.snapshots[0]!.docs;
  assert.equal(docs.find((d) => d.relPath === "a.md")!.changed, true);
  assert.equal(docs.find((d) => d.relPath === "b.md")!.changed, false);

  const undet = makeService({ listWorktrees: () => [wt], scan, changed: async () => undefined });
  undet.service.setWatchers(1);
  await flush();
  for (const d of undet.snapshots[0]!.docs) {
    assert.equal(d.changed, undefined, "undetermined changed must stay absent");
  }
});

test("scanOk is false for the whole snapshot when any worktree walk did not run", async () => {
  const h = makeService({
    scan: async () => ({ docs: [], scanOk: false, scanError: "walk failed" }),
  });
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.snapshots[0]!.scanOk, false);
});

test("a scan finishing after the last watcher leaves publishes nothing", async () => {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const h = makeService({
    changed: async () => {
      await gate;
      return new Set<string>();
    },
  });
  h.service.setWatchers(1);
  await flush();
  h.service.setWatchers(0);
  release();
  await flush();
  assert.equal(h.snapshots.length, 0);
});

test("the cached snapshot is handed to a freshly-arrived watcher", async () => {
  const h = makeService();
  h.service.setWatchers(1);
  await flush();
  const cached = h.service.cachedSnapshot();
  assert.ok(cached);
  assert.equal(cached!.docs[0]!.relPath, "spec.md");
});

test("publish refuses a non-allowlisted extension, minting no grant", async () => {
  const root = process.cwd();
  const h = makeService({ listWorktrees: () => [{ worktreePath: root, baseBranch: "main", currentBranch: "feat" }] });
  const pub = await h.service.publish(root, "package.json"); // resolves? .json is not allowlisted → refusal
  assert.equal(pub.ok, false, "a non-doc extension is refused");
  assert.deepEqual(h.service.grants(), []);
});

// The command layer refuses a worktreePath the index never reported; the service
// answers that question against its own worktree source (SPEC-44 owner model).
test("isIndexedWorktree is true only for a worktree the index reported", () => {
  const h = makeService({
    listWorktrees: () => [{ worktreePath: "/wt", baseBranch: "main", currentBranch: "feat" }],
  });
  assert.equal(h.service.isIndexedWorktree("/wt"), true);
  assert.equal(h.service.isIndexedWorktree("/somewhere-else"), false);
});

// D10 rev 2: the lazily-bound doc port must be released when the last grant is
// gone, and an EXPIRY has no event of its own — it is only discovered when
// `grants.list()` reaps it. So both unpublish and grants() must signal.
test("onGrantsChanged fires on unpublish and on a grants() that reaps the last grant", () => {
  let signals = 0;
  const h = makeService({
    listWorktrees: () => [],
    onGrantsChanged: () => {
      signals++;
    },
  });
  const { service: svc, grants } = h;

  const g = grants.mint({
    worktreePath: "/repo",
    relPath: "a.md",
    reach: "tailnet",
    buildUrl: (id) => `http://x/docs/${id}/a.md`,
  });

  svc.unpublish(g.grantId);
  assert.equal(signals, 1, "a revoke must signal so the port can be released");

  svc.grants();
  assert.equal(signals, 2, "listing must signal too — that is when an expiry is noticed");
});

// A live probe found this: the app sends `docs.watch {on:true}` from the home
// screen's initState, which lands BEFORE the server's first `repos.snapshot`.
// The 0→1 scan therefore sees NO worktrees and emits an empty index. If the scan
// result were memoized, or if a later worktree list did not produce a fresh
// walk, the Docs screen would stay permanently empty and never recover — which
// is exactly what happened against the real server (0 docs instead of 1008).
test("a re-index picks up worktrees that only appeared after the first scan", async () => {
  let worktrees: DocWorktree[] = [];
  const snapshots: DocsSnapshotDTO[] = [];
  const timers: Array<() => void> = [];

  const svc = new DocsService({
    listWorktrees: () => worktrees,
    exec: (async () => ({ code: 1, stdout: "", stderr: "" })) as Exec,
    grants: new DocGrantStore(),
    reach: async () => null,
    now: () => 1,
    onSnapshot: (s) => snapshots.push(s),
    setTimer: (fn) => {
      timers.push(fn);
      return 1;
    },
    clearTimer: () => {},
    scan: async (worktreePath): Promise<WorktreeScan> => ({
      docs: [
        {
          key: `${worktreePath}:mockups/b.html`,
          relPath: "mockups/b.html",
          title: "Board",
          kind: "html",
          bytes: 10,
          modifiedAt: 1,
          worktreePath,
        } as DocDTO,
      ],
      scanOk: true,
    }),
  });

  // Watch turns on before any worktree is known — the real race. The 0→1 edge
  // scans immediately (no debounce), which is why the empty result is what the
  // client receives.
  svc.setWatchers(1);
  await new Promise((r) => setImmediate(r));
  assert.equal(snapshots.at(-1)?.docs.length, 0, "first walk legitimately finds nothing");

  // The repos snapshot lands; server.ts calls onWorktreeChange().
  worktrees = [{ worktreePath: "/repo/wt", baseBranch: "main", currentBranch: "feat/x" }];
  svc.onWorktreeChange();
  for (const fn of timers.splice(0)) fn();
  await new Promise((r) => setImmediate(r));

  assert.equal(
    snapshots.at(-1)?.docs.length,
    1,
    "the re-index must walk again and find the newly-known worktree",
  );
});


// Every caller is `void runScan()`, so a throwing scan used to escape as an
// unhandled rejection: nothing published, nothing reported, the Docs screen
// simply frozen on its last snapshot. It must degrade to scanOk:false instead.
test("a throwing scan publishes scanOk:false rather than rejecting unhandled", async () => {
  const h = makeService({
    scan: async () => {
      throw new Error("git exploded");
    },
  });
  h.service.setWatchers(1);
  await flush();
  const snap = h.snapshots.at(-1);
  assert.ok(snap, "a failure must still publish a snapshot");
  assert.equal(snap?.scanOk, false);
  assert.match(snap?.scanError ?? "", /git exploded/);
  assert.deepEqual(snap?.docs, []);
});
