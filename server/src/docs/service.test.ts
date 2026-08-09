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
  scan?: (worktreePath: string) => WorktreeScan;
  changed?: () => Promise<ReadonlySet<string> | undefined>;
  exec?: Exec;
} = {}) {
  const snapshots: DocsSnapshotDTO[] = [];
  const timers: { fn: () => void; cancelled: boolean }[] = [];
  let clears = 0;
  const grants = new DocGrantStore();

  const defaultScan = (worktreePath: string): WorktreeScan => ({
    docs: [docOf(worktreePath, "spec.md")],
    scanOk: true,
  });

  const service = new DocsService({
    listWorktrees: overrides.listWorktrees ?? (() => [{ worktreePath: "/wt", baseBranch: "main", currentBranch: "feat" }]),
    exec: overrides.exec ?? (async () => ({ code: 0, stdout: "", stderr: "" })),
    grants,
    reach: async () => ({ origin: "https://host.ts.net", reach: "tailnet" }),
    scan: overrides.scan ?? defaultScan,
    changedPaths: overrides.changed ?? (async () => new Set<string>()),
    onSnapshot: (s) => snapshots.push(s),
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
  const scan = (worktreePath: string): WorktreeScan => ({
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
    scan: () => ({ docs: [], scanOk: false, scanError: "walk failed" }),
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

test("publish/unpublish/grants delegate to the grant store", async () => {
  const root = process.cwd();
  const h = makeService({ listWorktrees: () => [{ worktreePath: root, baseBranch: "main", currentBranch: "feat" }] });
  const pub = await h.service.publish(root, "package.json"); // resolves? .json is not allowlisted → refusal
  assert.equal(pub.ok, false, "a non-doc extension is refused");
  assert.deepEqual(h.service.grants(), []);
});
