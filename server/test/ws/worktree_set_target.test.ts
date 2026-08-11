/**
 * The bug this whole feature exists for, end to end.
 *
 * A worktree stacked on another worktree's branch reported the PARENT's work as
 * its own, because `repo_service` handed the repo's default branch to `diffStat`
 * for every worktree regardless of what that worktree was actually destined for
 * (`diffStat(e.path, defaultBranch)`). The base the user picked at creation time
 * was used once for `git worktree add` and then discarded.
 *
 * This drives a real {@link startWsServer} against a real git repo with a real
 * two-level stack and asserts:
 *  * the child's diff is inflated by the parent's commits while it targets `main`,
 *  * `worktree.setTarget` collapses it to the child's own delta,
 *  * the new numbers arrive on the very next `repos.snapshot` with no further
 *    action (R1: persist happens before the broadcast, so the snapshot that
 *    follows cannot have been computed against the old target),
 *  * an unknown ref is refused (R10) and leaves the stored target untouched.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";

import { SessionManager } from "../../src/manager.js";
import { startWsServer } from "../../src/server.js";
import { loadOrCreateCert } from "../../src/pairing/cert.js";
import { DeviceRegistry } from "../../src/pairing/registry.js";
import { StubAdapter } from "../../src/adapters/stub.js";

interface Client {
  ws: WebSocket;
  msgs: Record<string, unknown>[];
}

function connect(port: number): Client {
  const ws = new WebSocket(`wss://127.0.0.1:${port}`, { rejectUnauthorized: false });
  const msgs: Record<string, unknown>[] = [];
  ws.on("message", (b: Buffer) => {
    try {
      msgs.push(JSON.parse(b.toString()));
    } catch {
      /* ignore non-JSON */
    }
  });
  return { ws, msgs };
}

function waitOpen(ws: WebSocket): Promise<void> {
  return new Promise((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", reject);
  });
}

async function waitFor(pred: () => boolean, label = "condition", timeoutMs = 8000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (pred()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

interface WtDTO {
  path: string;
  branch: string | null;
  targetBranch: string | null;
  targetResolved: boolean;
  insertions: number;
  deletions: number;
}

const isReposSnapshot = (m: Record<string, unknown>) =>
  m.t === "event" && m.kind === "repos.snapshot";

/** The worktrees from the most recent `repos.snapshot`. */
function latestWorktrees(c: Client): WtDTO[] {
  const snaps = c.msgs.filter(isReposSnapshot);
  const last = snaps[snaps.length - 1]!;
  const repos = last.repos as Array<{ worktrees: WtDTO[] }>;
  return repos.flatMap((r) => r.worktrees);
}

function byBranch(c: Client, branch: string): WtDTO {
  const wt = latestWorktrees(c).find((w) => w.branch === branch);
  assert.ok(wt, `no worktree on branch ${branch}; saw ${latestWorktrees(c).map((w) => w.branch).join(", ")}`);
  return wt;
}

/** Wait for the snapshot burst to settle, then return the count seen. */
async function settle(c: Client): Promise<number> {
  await waitFor(() => c.msgs.filter(isReposSnapshot).length > 0, "first repos.snapshot");
  let stable = -1;
  for (let quiet = 0; quiet < 4; quiet++) {
    await new Promise((r) => setTimeout(r, 120));
    const n = c.msgs.filter(isReposSnapshot).length;
    if (n !== stable) {
      stable = n;
      quiet = -1;
    }
  }
  return stable;
}

test("setTarget retargets a stacked worktree's diff to its parent", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-target-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-target-proj-"));
  const wtDir = mkdtempSync(join(tmpdir(), "makit-target-wt-"));
  const prevHome = process.env.MAKIT_HOME;
  const prevWtDir = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_HOME = home;
  process.env.MAKIT_WORKTREE_DIR = wtDir;

  const g = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd });
  // A repo on `main` with one commit.
  g(project, "init", "-q", "-b", "main");
  g(project, "config", "user.email", "t@t.io");
  g(project, "config", "user.name", "Test");
  writeFileSync(join(project, "README.md"), "base\n");
  g(project, "add", ".");
  g(project, "commit", "-q", "-m", "initial");

  // The PARENT branch: 20 added lines, committed.
  const parentPath = join(wtDir, "parent");
  g(project, "worktree", "add", "-q", "-b", "feat/parent", parentPath, "main");
  writeFileSync(join(parentPath, "parent.txt"), Array.from({ length: 20 }, (_, i) => `p${i}`).join("\n") + "\n");
  g(parentPath, "add", ".");
  g(parentPath, "commit", "-q", "-m", "parent work");

  // The CHILD branch, forked off the parent: 3 more lines.
  const childPath = join(wtDir, "child");
  g(project, "worktree", "add", "-q", "-b", "feat/child", childPath, "feat/parent");
  writeFileSync(join(childPath, "child.txt"), "c0\nc1\nc2\n");
  g(childPath, "add", ".");
  g(childPath, "commit", "-q", "-m", "child work");

  const manager = new SessionManager({
    projects: [project],
    adapterFactory: () => new StubAdapter(),
  });
  const cert = await loadOrCreateCert();
  const srv = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager,
    cert,
    registry: new DeviceRegistry(),
    trustLocalhost: true,
  });
  await new Promise<void>((resolve) => {
    if (srv.https.listening) resolve();
    else srv.https.once("listening", () => resolve());
  });
  const port = (srv.https.address() as AddressInfo).port;

  const c = connect(port);
  try {
    await waitOpen(c.ws);
    await settle(c);

    // ── Before: the child is measured against `main`, so it carries the
    //    parent's 20 lines plus its own 3.
    const childBefore = byBranch(c, "feat/child");
    assert.equal(childBefore.targetBranch, "main", "defaults to the repo default (safe upgrade seed)");
    assert.equal(childBefore.targetResolved, true);
    assert.equal(
      childBefore.insertions,
      23,
      `the stacked worktree should be inflated by its parent's work, got ${childBefore.insertions}`,
    );

    // ── Retarget the child at its actual parent.
    // Use the path from the SNAPSHOT, not our local `childPath`: git reports
    // worktree paths symlink-resolved (on macOS `/var` -> `/private/var`), and
    // `_locateWorktree` matches on that. The app is never in a position to send
    // anything else, since every path it knows came from a snapshot.
    const childId = childBefore.path;
    const before = c.msgs.filter(isReposSnapshot).length;
    c.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "set-1",
        kind: "worktree.setTarget",
        projectId: manager.listProjects()[0]!.id,
        worktreePath: childId,
        targetBranch: "feat/parent",
      }),
    );
    await waitFor(
      () => c.msgs.some((m) => (m.t === "ack" || m.t === "err") && m.id === "set-1"),
      "setTarget reply",
    );
    const reply = c.msgs.find((m) => m.id === "set-1")!;
    assert.equal(reply.t, "ack", `setTarget failed: ${JSON.stringify(reply)}`);
    assert.equal(reply.targetBranch, "feat/parent", `unexpected ack: ${JSON.stringify(reply)}`);

    // ── After: the very next snapshot carries the corrected numbers. If the
    //    persist had happened after the broadcast (R1 violated) this frame would
    //    still say 23.
    await waitFor(() => c.msgs.filter(isReposSnapshot).length > before, "post-setTarget snapshot");
    await settle(c);
    const childAfter = byBranch(c, "feat/child");
    assert.equal(childAfter.targetBranch, "feat/parent");
    assert.equal(childAfter.targetResolved, true);
    assert.equal(
      childAfter.insertions,
      3,
      `retargeting should leave only the child's own delta, got ${childAfter.insertions}`,
    );

    // The parent is untouched: retargeting one worktree must not disturb another.
    const parent = byBranch(c, "feat/parent");
    assert.equal(parent.targetBranch, "main");
    assert.equal(parent.insertions, 20);

    // ── R10: an unknown ref is refused, and the stored target does not move.
    c.ws.send(
      JSON.stringify({
        v: 1,
        t: "cmd",
        id: "set-bad",
        kind: "worktree.setTarget",
        projectId: manager.listProjects()[0]!.id,
        worktreePath: childId,
        targetBranch: "no/such/branch",
      }),
    );
    await waitFor(() => c.msgs.some((m) => m.t === "err" && m.id === "set-bad"), "setTarget rejection");
    await settle(c);
    assert.equal(byBranch(c, "feat/child").targetBranch, "feat/parent", "a rejected setTarget must not change anything");
  } finally {
    c.ws.close();
    srv.https.close();
    srv.wss.close();

    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    if (prevWtDir === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevWtDir;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
    rmSync(wtDir, { recursive: true, force: true });
  }
});
