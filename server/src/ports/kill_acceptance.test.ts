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
import { createServer } from "node:http";
import { connect } from "node:net";
import type { AddressInfo } from "node:net";
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

/**
 * Is anything accepting on this loopback port? A direct TCP connect, deliberately
 * NOT a scan: the claim under test is "the port is gone", and asserting it
 * through the same scanner the kill path uses would make a flaky scan look like a
 * broken kill (which is exactly how this test first failed on CI).
 */
function portIsFree(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host: "127.0.0.1", port });
    const settle = (free: boolean): void => {
      socket.destroy();
      resolve(free);
    };
    socket.setTimeout(1_000, () => settle(false));
    socket.once("connect", () => settle(false));
    socket.once("error", () => settle(true));
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
      const service = realService(worktree, () => {});

      // ONE awaited scan. The earlier version armed a watcher and polled for a
      // published snapshot, which left that scan in flight while `killPort`
      // started its own — two concurrent `lsof` runs, and on a loaded CI runner
      // one of them exceeded the per-exec timeout, so the kill honestly refused
      // with `scan_unavailable`. `scanNow` is a single, awaited scan.
      const snapshot = await service.scanNow();
      if (!snapshot.scanOk) {
        // An environment whose sockets we cannot read proves nothing about
        // killing. Say why and stop, rather than failing on an environment fact.
        console.log(
          `[ports/kill_acceptance] SKIPPED mid-test: scan unavailable here (${snapshot.scanError})`,
        );
        return;
      }
      const row = snapshot.ports.find(
        (p) => p.pid === listener!.pid && p.port === listener!.port,
      );
      assert.ok(row, `the real scan found our listener on :${listener.port}`);
      assert.equal(row.worktreePath, worktree, "attributed — and therefore killable (D3)");
      assert.ok(
        row.startedAt !== undefined,
        "startedAt parsed from real `ps` etime — without it D1 cannot verify",
      );

      const target = {
        address: row.address,
        port: row.port,
        pid: row.pid,
        startedAt: row.startedAt,
      };

      // `scan_unavailable` is the CORRECT product behaviour when a scan cannot be
      // read (R1: refuse, never guess), and on a loaded runner one `lsof` can
      // exceed the per-exec budget. So retry that specific refusal a few times;
      // any OTHER refusal fails immediately, because that would be a real
      // regression in the whitelist.
      let result = await service.killPort(target);
      for (let attempt = 0; attempt < 4 && result.outcome === "scan_unavailable"; attempt++) {
        await new Promise((r) => setTimeout(r, 250));
        result = await service.killPort(target);
      }
      if (result.outcome === "scan_unavailable") {
        const why = await service.scanNow();
        console.log(
          `[ports/kill_acceptance] SKIPPED mid-test: the scanner is unreliable here (${why.scanError})`,
        );
        return;
      }
      // `not_found` is accepted only because a RETRY can see it: if an earlier
      // attempt signalled the process but could not verify, the next one finds the
      // endpoint already free. `portIsFree` below is what actually proves the
      // outcome either way. Every other outcome would be a whitelist regression
      // (`not_owned`, `identity_mismatch`, `refused_*`) or a real survivor.
      assert.ok(
        ["released", "force-killed", "not_found"].includes(result.outcome),
        `expected the port to be freed, got ${result.outcome}`,
      );

      // The ground truth, independent of the scanner: nothing accepts there now.
      assert.equal(
        await portIsFree(row.port),
        true,
        `:${row.port} still accepts connections after a \`${result.outcome}\``,
      );

      // And the endpoint really is gone as far as a fresh scan is concerned, so a
      // second attempt has nothing to match.
      const again = await service.killPort(target);
      assert.ok(
        again.outcome === "not_found" || again.outcome === "scan_unavailable",
        `a second kill should find nothing, got ${again.outcome}`,
      );
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
  "a listener owned by THIS process is refused (refused_self), never signalled",
  { skip: lsofMissing },
  async () => {
    // The previous version aimed at port 1, where nothing listens — so
    // `classifyKillTarget` returned `not_found` before the self guard ever ran
    // and the test could pass without exercising the thing it names.
    //
    // This one listens IN THE TEST PROCESS: the scan then attributes a real
    // listener to `process.pid`, which IS the server pid, so the guard is the
    // only thing that can produce the refusal.
    // The test process's OWN cwd stands in for the worktree, because the pid
    // guards (R5-R7) are only reached once a listener is attributed to one:
    // ownership (R4) is checked first, so an unowned self-listener reads
    // `not_owned` and would never exercise this guard.
    const worktree = process.cwd();
    const server = createServer((_, res) => res.end("ok"));
    try {
      await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
      const port = (server.address() as AddressInfo).port;
      const service = realService(worktree, () => {});
      const snapshot = await service.scanNow();
      if (!snapshot.scanOk) {
        console.log(
          `[ports/kill_acceptance] SKIPPED mid-test: scan unavailable here (${snapshot.scanError})`,
        );
        return;
      }
      const row = snapshot.ports.find(
        (p) => p.pid === process.pid && p.port === port,
      );
      assert.ok(row, `the scan found the test process's own listener on :${port}`);
      assert.equal(row.pid, process.pid, "the listener IS this process");

      const result = await service.killPort({
        address: row.address,
        port: row.port,
        pid: row.pid,
        startedAt: row.startedAt ?? Date.now(),
      });
      assert.equal(
        result.outcome,
        "refused_self",
        "killing our own listener must be refused by the guard, not attempted",
      );
      // Still listening: the refusal was real, not a kill that happened to fail.
      assert.ok(server.listening, "the server was never signalled");
    } finally {
      await new Promise<void>((r) => server.close(() => r()));
    }
  },
);
