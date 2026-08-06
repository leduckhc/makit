import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { run } from "../git.js";
import { listListeners } from "./scan.js";
import { readProcs, readCwds, createRealpathResolver } from "./proc.js";
import { cwdPidSet } from "./ancestors.js";
import { attribute } from "./attribute.js";

/** lsof is macOS/BSD/Linux; skip (with a printed reason) where it is absent. */
function haveLsof(): boolean {
  try {
    execFileSync("which", ["lsof"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

const lsofMissing = !haveLsof();
if (lsofMissing) console.log("[ports/acceptance] SKIPPED: `lsof` is not on PATH (Linux CI without it)");

/** Spawn a real node HTTP listener with `cwd` set to `dir`; resolve its {pid, port}. */
function startListener(dir: string): Promise<{ pid: number; port: number; kill: () => void }> {
  const script =
    "const http=require('http');" +
    "const s=http.createServer((_,res)=>res.end('ok'));" +
    "s.listen(0,'127.0.0.1',()=>process.stdout.write('PORT='+s.address().port+'\\n'));";
  const child = spawn(process.execPath, ["-e", script], { cwd: dir, stdio: ["ignore", "pipe", "ignore"] });
  return new Promise((resolvePromise, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error("listener did not report a port in time")), 5_000);
    child.stdout.on("data", (chunk: Buffer) => {
      buf += chunk.toString();
      const m = buf.match(/PORT=(\d+)/);
      if (m) {
        clearTimeout(timer);
        resolvePromise({ pid: child.pid!, port: Number(m[1]), kill: () => child.kill("SIGKILL") });
      }
    });
    child.on("error", reject);
  });
}

test("a real listener in a real worktree is attributed to that worktree", { skip: lsofMissing }, async () => {
  const repo = mkdtempSync(join(tmpdir(), "ports-repo-"));
  const worktree = mkdtempSync(join(tmpdir(), "ports-wt-"));
  let listener: Awaited<ReturnType<typeof startListener>> | undefined;
  try {
    // A real git repo + worktree, so the path we assert on is a genuine worktree.
    execFileSync("git", ["init", "-q"], { cwd: repo });
    execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], {
      cwd: repo,
    });
    execFileSync("git", ["worktree", "add", "-q", worktree, "-b", "feat/ports-accept"], { cwd: repo });

    listener = await startListener(worktree);

    // Run the REAL scanner (real lsof/ps), exactly as the service does.
    const now = Date.now();
    const scan = await listListeners(run);
    assert.ok(scan.ok, "lsof ran");
    const procs = await readProcs(run, now);
    const pidSet = cwdPidSet(scan.listeners.map((l) => l.pid), procs);
    const cwds = await readCwds(run, [...pidSet]);
    const ports = attribute({
      listeners: scan.listeners,
      procs,
      cwds,
      worktreePaths: [worktree],
      sessionRoots: new Map(),
      health: () => undefined,
      tailnetAddress: null,
      resolveReal: createRealpathResolver(),
    });

    const mine = ports.find((p) => p.pid === listener!.pid && p.port === listener!.port);
    assert.ok(mine, `the scan found our listener on :${listener.port}`);
    assert.equal(mine!.worktreePath, worktree, "attributed to the worktree it was launched from");
    // realpathSync collapses the /var → /private/var alias; the resolver must have too.
    assert.equal(realpathSync(mine!.worktreePath!), realpathSync(worktree));
  } finally {
    listener?.kill();
    execFileSync("git", ["worktree", "remove", "--force", worktree], { cwd: repo, stdio: "ignore" });
  }
});
