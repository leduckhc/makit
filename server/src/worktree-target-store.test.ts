/**
 * Tests for the per-worktree target-branch store.
 *
 * The interesting behaviour is not "can it round-trip a string" but the three
 * hazards the design review surfaced (§0 B2, R9):
 *  * a torn write must never be observable (R9 atomicity),
 *  * a removed-and-recreated worktree must not inherit the dead one's target,
 *    because `addWorktree` derives its path deterministically from repo + name,
 *  * a corrupt or missing file must degrade to "no targets", never throw, so the
 *    server always starts.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  loadTargets,
  saveTargets,
  putTarget,
  clearTarget,
  pruneTargets,
  targetOf,
  renameTargetBranch,
} from "./worktree-target-store.js";

function tmpFile(): { dir: string; file: string } {
  const dir = mkdtempSync(join(tmpdir(), "makit-targets-"));
  return { dir, file: join(dir, "worktree-targets.json") };
}

test("loadTargets returns an empty map for a missing file", () => {
  const { dir, file } = tmpFile();
  try {
    assert.deepEqual(loadTargets(file), {});
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadTargets degrades to empty on a corrupt file rather than throwing", () => {
  const { dir, file } = tmpFile();
  try {
    writeFileSync(file, "{ this is not json");
    assert.deepEqual(loadTargets(file), {});
    // Wrong shape at the top level.
    writeFileSync(file, JSON.stringify({ targets: "nope" }));
    assert.deepEqual(loadTargets(file), {});
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadTargets drops legacy entries whose value is not a branch string", () => {
  const { dir, file } = tmpFile();
  try {
    writeFileSync(
      file,
      JSON.stringify({ targets: { "/a": "main", "/b": 7, "/c": null, "/d": "" } }),
    );
    assert.deepEqual(loadTargets(file), { "/a": { target: "main" } });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("putTarget persists and is readable back", () => {
  const { dir, file } = tmpFile();
  try {
    putTarget(file, "/wt/a", "main");
    putTarget(file, "/wt/b", "feat/parent");
    assert.deepEqual(loadTargets(file), {
      "/wt/a": { target: "main" },
      "/wt/b": { target: "feat/parent" },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("putTarget overwrites only its own key", () => {
  const { dir, file } = tmpFile();
  try {
    putTarget(file, "/wt/a", "main");
    putTarget(file, "/wt/b", "feat/parent");
    putTarget(file, "/wt/a", "release/1.4");
    assert.deepEqual(loadTargets(file), {
      "/wt/a": { target: "release/1.4" },
      "/wt/b": { target: "feat/parent" },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("clearTarget removes one key and leaves the rest", () => {
  const { dir, file } = tmpFile();
  try {
    putTarget(file, "/wt/a", "main");
    putTarget(file, "/wt/b", "feat/parent");
    clearTarget(file, "/wt/a");
    assert.deepEqual(loadTargets(file), { "/wt/b": { target: "feat/parent" } });
    // Clearing something absent is a no-op, not an error.
    clearTarget(file, "/wt/nope");
    assert.deepEqual(loadTargets(file), { "/wt/b": { target: "feat/parent" } });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

/**
 * R9: the write must be atomic. We cannot easily induce a real crash mid-write,
 * so we assert the mechanism instead: the file is replaced by rename, so no
 * partial JSON is ever observable and no temp files are left behind.
 */
test("saveTargets writes atomically and leaves no temp files behind", () => {
  const { dir, file } = tmpFile();
  try {
    saveTargets(file, { "/wt/a": { target: "main" } });
    // Valid JSON after the write, and exactly one file in the directory.
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), {
      targets: { "/wt/a": { target: "main" } },
    });
    assert.deepEqual(readdirSync(dir), ["worktree-targets.json"]);
    // A second write also leaves the dir clean (no accumulating .tmp siblings).
    saveTargets(file, { "/wt/a": { target: "release/1.4" } });
    assert.deepEqual(readdirSync(dir), ["worktree-targets.json"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("saveTargets creates the parent directory", () => {
  const { dir } = tmpFile();
  try {
    const nested = join(dir, "deep", "deeper", "worktree-targets.json");
    saveTargets(nested, { "/wt/a": { target: "main" } });
    assert.deepEqual(loadTargets(nested), { "/wt/a": { target: "main" } });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

/**
 * B2's sharpest hazard: `addWorktree` builds its path as
 * `<baseDir>/<repoName>/<name>`, so removing a worktree and creating another
 * with the same name yields the SAME path. Without a prune, the new worktree
 * silently inherits the dead one's target.
 */
test("pruneTargets drops entries for worktrees that no longer exist", () => {
  const { dir, file } = tmpFile();
  try {
    saveTargets(file, {
      "/wt/live": { target: "main" },
      "/wt/dead": { target: "feat/gone" },
      "/wt/also-live": { target: "release/1.4" },
    });
    const removed = pruneTargets(file, ["/wt/live", "/wt/also-live"]);
    assert.equal(removed, 1);
    assert.deepEqual(loadTargets(file), {
      "/wt/live": { target: "main" },
      "/wt/also-live": { target: "release/1.4" },
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("pruneTargets does not rewrite the file when nothing is stale", () => {
  const { dir, file } = tmpFile();
  try {
    saveTargets(file, { "/wt/live": { target: "main" } });
    const before = readFileSync(file, "utf8");
    const removed = pruneTargets(file, ["/wt/live"]);
    assert.equal(removed, 0);
    // Byte-identical: a no-op prune must not churn the file on every snapshot.
    assert.equal(readFileSync(file, "utf8"), before);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("pruneTargets with an empty live set clears everything", () => {
  const { dir, file } = tmpFile();
  try {
    saveTargets(file, { "/wt/a": { target: "main" }, "/wt/b": { target: "main" } });
    assert.equal(pruneTargets(file, []), 2);
    assert.deepEqual(loadTargets(file), {});
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

/**
 * R9 again, from the read-modify-write angle: `putTarget` loads, mutates and
 * saves. Sequential calls must compose — last write wins per key, and no
 * earlier key is lost.
 */
test("interleaved putTarget calls compose without losing keys", () => {
  const { dir, file } = tmpFile();
  try {
    for (let i = 0; i < 25; i++) putTarget(file, `/wt/${i}`, i % 2 ? "main" : "feat/parent");
    const all = loadTargets(file);
    assert.equal(Object.keys(all).length, 25);
    assert.equal(all["/wt/24"]?.target, "feat/parent");
    assert.equal(all["/wt/23"]?.target, "main");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Richer entries: a target plus "what it used to be", so an automatic repoint
// can be announced instead of happening behind the user's back.
// ─────────────────────────────────────────────────────────────────────────────

test("an entry can carry what the target used to be", () => {
  const { dir, file } = tmpFile();
  try {
    putTarget(file, "/wt/a", "main", { retargetedFrom: "feat/parent" });
    assert.deepEqual(loadTargets(file), {
      "/wt/a": { target: "main", retargetedFrom: "feat/parent" },
    });
    assert.equal(targetOf(file, "/wt/a"), "main");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("putTarget without a note clears any previous note", () => {
  const { dir, file } = tmpFile();
  try {
    putTarget(file, "/wt/a", "main", { retargetedFrom: "feat/parent" });
    // An explicit choice means the user has taken ownership: there is nothing
    // left to announce, so the note must not linger.
    putTarget(file, "/wt/a", "release/1.4");
    assert.deepEqual(loadTargets(file), { "/wt/a": { target: "release/1.4" } });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadTargets still reads the legacy bare-string shape", () => {
  const { dir, file } = tmpFile();
  try {
    // The first version of this file stored `path -> "branch"`. Upgrading must
    // not silently drop everyone's targets.
    writeFileSync(file, JSON.stringify({ targets: { "/wt/a": "main" } }));
    assert.deepEqual(loadTargets(file), { "/wt/a": { target: "main" } });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadTargets drops an entry whose target is not a usable string", () => {
  const { dir, file } = tmpFile();
  try {
    writeFileSync(
      file,
      JSON.stringify({
        targets: {
          "/ok": { target: "main" },
          "/empty": { target: "" },
          "/num": { target: 7 },
          "/missing": { retargetedFrom: "x" },
        },
      }),
    );
    assert.deepEqual(loadTargets(file), { "/ok": { target: "main" } });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ── rule 2: a branch rename must follow through ──────────────────────────────

test("renameTargetBranch repoints every worktree that landed in the old name", () => {
  const { dir, file } = tmpFile();
  try {
    putTarget(file, "/wt/a", "feat/parent");
    putTarget(file, "/wt/b", "feat/parent");
    putTarget(file, "/wt/c", "main");
    const moved = renameTargetBranch(file, "feat/parent", "feat/renamed");
    assert.equal(moved, 2);
    assert.equal(targetOf(file, "/wt/a"), "feat/renamed");
    assert.equal(targetOf(file, "/wt/b"), "feat/renamed");
    assert.equal(targetOf(file, "/wt/c"), "main", "unrelated targets are untouched");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("renameTargetBranch is a silent no-op when nothing points at the old name", () => {
  const { dir, file } = tmpFile();
  try {
    putTarget(file, "/wt/a", "main");
    const before = readFileSync(file, "utf8");
    assert.equal(renameTargetBranch(file, "feat/nope", "feat/other"), 0);
    assert.equal(readFileSync(file, "utf8"), before, "must not churn the file");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("renameTargetBranch preserves an existing note", () => {
  const { dir, file } = tmpFile();
  try {
    putTarget(file, "/wt/a", "feat/parent", { retargetedFrom: "old" });
    renameTargetBranch(file, "feat/parent", "feat/new");
    assert.deepEqual(loadTargets(file)["/wt/a"], {
      target: "feat/new",
      retargetedFrom: "old",
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("saveTargets/putTarget return false when the write cannot land", () => {
  // Point the store under a path whose parent is a regular FILE, so the
  // atomic-write's `mkdirSync` fails with ENOTDIR — a deterministic write
  // failure. The interactive command relies on this signal to avoid acking a
  // success the disk refused.
  const { dir } = tmpFile();
  try {
    const blocker = join(dir, "blocker");
    writeFileSync(blocker, "not a directory");
    const file = join(blocker, "sub", "worktree-targets.json");
    assert.equal(saveTargets(file, { "/wt": { target: "main" } }), false);
    assert.equal(putTarget(file, "/wt", "main"), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("saveTargets/putTarget return true on a successful write", () => {
  const { dir, file } = tmpFile();
  try {
    assert.equal(saveTargets(file, { "/wt": { target: "main" } }), true);
    assert.equal(putTarget(file, "/wt2", "dev"), true);
    assert.equal(targetOf(file, "/wt2"), "dev");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
