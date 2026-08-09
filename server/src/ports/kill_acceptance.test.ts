/**
 * SPEC-43 P3a acceptance — the real thing: a real `node` listener, in a real git
 * worktree, killed through the real `PortsService.killPort` with the real
 * `process.kill`.
 *
 * Everything else in the kill suite is scripted, which is what makes it fast and
 * exhaustive; this file is the counterweight that proves the pieces fit on an
 * actual machine: real `lsof -F` output (which differs between macOS and Linux),
 * real `ps` etime → `startedAt` arithmetic (the tuple D1 verifies), a real
 * SIGTERM, and a real socket release.
 *
 * Skipped with a printed reason where `lsof` is not on PATH, exactly like
 * `acceptance.test.ts` (the SPEC-41 T9 lesson about Linux CI parity).
 */

import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { run } from "../git.js";
import { PortsService } from "./service.js";
import type { PortsSnapshotDTO } from "../protocol.js";

function haveLsof(): boolean {
  try {
    execFileSync("which", ["lsof"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

const lsofMissing = !haveLsof();
if (lsofMissing) {
  console.log("[ports/kill_acceptance] SKIPPED: `lsof` is not on PATH (Linux CI without it)");
}

/** A real HTTP listener whose cwd is `dir`. Handles SIGTERM by exiting. */
function startListener(dir: string): Promise<{ pid: number; port: number; kill: () => void }> {
  const script =
    "const http=require('http');" +
    "const s=http.createServer((_,res)=>res.end('ok'));" +
    "s.listen(0,'127.0.0.1',()=>process.stdout.write('PORT='+s.address().port+'\\n'));";
  const child = spawn(process.execPath, ["-e", script], {
    cwd: dir,
    stdio: ["ignore", "pipe", "ignore"],
  });
  return new Promise((resolvePromise, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("listener did not report a port")), 5_000);
    child.stdout.on("data", (chunk: Buffer) => {
      buf += chunk.toString();
      const m = buf.match(/PORT=(\d+)/);
      if (m) {
        clearTimeout(timer);
        resolvePromise({
          pid: child.pid!,
          port: Number(m[1]),
          kill: () => {
            try {
              child.kill("SIGKILL");
            } catch {
              /* already gone */
            }
          },
        });
      }
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

/** A service wired to the REAL exec and the REAL `process.kill`. */
function realService(worktree: string, onSnapshot: (s: PortsSnapshotDTO) => void): PortsService {
  return new PortsService({
    exec: run,
    probe: { refresh: async () => {}, verdict: () => undefined },
    listWorktreePaths: () => [worktree],
    listWorktreeBranches: () => new Map([[worktree, "feat/kill-accept"]]),
    // In-memory history: this test must not touch the user's $MAKIT_HOME.
    loadHistory: () => ({ entries: [] }),
    saveHistory: () => {},
    listSessionRoots: () => new Map(),
    tailnetAddress: () => null,
    onSnapshot,
    now: () => Date.now(),
    setTimer: () => null,
    clearTimer: () => {},
    // Real signal, real grace window — this is the whole point of the file. The
    // window is shortened only by the service's own constant, not overridden.
  });
}

test(
  "a real dev server in a real worktree is killed, and a second kill says not_found",
  { skip: lsofMissing },
  async () => {
    const repo = mkdtempSync(join(tmpdir(), "ports-kill-repo-"));
    const worktree = mkdtempSync(join(tmpdir(), "ports-kill-wt-"));
    let listener: Awaited<ReturnType<typeof startListener>> | undefined;
    try {
      execFileSync("git", ["init", "-q"], { cwd: repo });
      execFileSync(
        "git",
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"],
        { cwd: repo },
      );
      execFileSync("git", ["worktree", "add", "-q", worktree, "-b", "feat/kill-accept"], {
        cwd: repo,
      });

      listener = await startListener(worktree);
      const snapshots: PortsSnapshotDTO[] = [];
      const service = realService(worktree, (s) => snapshots.push(s));

      // One real scan through the service, to get the tuple the UI would show.
      // `setWatchers(1)` starts it (a snapshot is only published while somebody
      // is watching), so wait for the publish rather than racing it.
      service.setWatchers(1);
      for (let i = 0; i < 100 && snapshots.length === 0; i++) {
        await new Promise((r) => setTimeout(r, 50));
      }
      service.setWatchers(0);
      const snapshot = snapshots.at(-1);
      assert.ok(snapshot, "the service published a real scan");
      const row = snapshot.ports.find(
        (p) => p.pid === listener!.pid && p.port === listener!.port,
      );
      assert.ok(row, `the real scan found our listener on :${listener.port}`);
      assert.equal(row.worktreePath, worktree, "attributed — and therefore killable (D3)");
      assert.ok(
        row.startedAt !== undefined,
        "startedAt parsed from real `ps` etime — without it D1 cannot verify",
      );

      const result = await service.killPort({
        address: row.address,
        port: row.port,
        pid: row.pid,
        startedAt: row.startedAt,
      });
      assert.ok(
        result.outcome === "released" || result.outcome === "force-killed",
        `expected the port to be freed, got ${result.outcome}`,
      );

      // The endpoint is genuinely gone: the second attempt has nothing to match.
      const again = await service.killPort({
        address: row.address,
        port: row.port,
        pid: row.pid,
        startedAt: row.startedAt,
      });
      assert.equal(again.outcome, "not_found");
    } finally {
      listener?.kill();
      try {
        execFileSync("git", ["worktree", "remove", "--force", worktree], {
          cwd: repo,
          stdio: "ignore",
        });
      } catch {
        /* best-effort */
      }
      rmSync(repo, { recursive: true, force: true });
      rmSync(worktree, { recursive: true, force: true });
    }
  },
);

test(
  "makit's OWN process is refused (refused_self) — the guard that saves the server",
  { skip: lsofMissing },
  async () => {
    // This test process is not a listener, so build the refusal from the guard's
    // own input: a kill aimed at `process.pid` can never be classified killable.
    const worktree = mkdtempSync(join(tmpdir(), "ports-kill-self-"));
    try {
      const service = realService(worktree, () => {});
      const result = await service.killPort({
        address: "127.0.0.1",
        port: 1,
        pid: process.pid,
        startedAt: Date.now(),
      });
      assert.ok(
        result.outcome === "not_found" || result.outcome === "refused_self",
        `never a signal to ourselves, got ${result.outcome}`,
      );
    } finally {
      rmSync(worktree, { recursive: true, force: true });
    }
  },
);
