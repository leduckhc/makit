// Capture ONE real `ports.snapshot` from the real server code path on this
// machine, so the PR recording is driven by genuine lsof/ps output rather than
// hand-written fixtures.
//
//   pnpm exec tsx tool/capture-ports-snapshot.ts > /tmp/ports-snapshot.json
//
// Uses the same deps `server.ts` wires in production: the real `git.run` exec,
// the real `PortHealthProbe` over real TCP, and the real worktree list from
// `git worktree list`. History is in-memory (a recording must not mutate the
// user's $MAKIT_HOME store).
import { execFile } from "node:child_process";
import { PortsService } from "../src/ports/service.js";
import { PortHealthProbe, createNetConnector } from "../src/ports/health.js";
import { run as execRun } from "../src/git.js";
import type { PortsSnapshotDTO } from "../src/protocol.js";

const REPO = process.argv[2] ?? process.cwd();
/// Which snapshot to keep. Health is stale-while-revalidate (spec D3): the first
/// scan carries socket facts only and the probe verdict lands on a later tick, so
/// a recording of the health pills must wait for it.
const WANT = Number(process.argv[3] ?? 3);

/** `git worktree list --porcelain` → [absolute path, branch]. */
async function worktrees(): Promise<Map<string, string>> {
  const out = await new Promise<string>((resolve, reject) => {
    execFile(
      "git",
      ["-C", REPO, "worktree", "list", "--porcelain"],
      (err, stdout) => (err ? reject(err) : resolve(stdout)),
    );
  });
  const map = new Map<string, string>();
  let path = "";
  for (const line of out.split("\n")) {
    if (line.startsWith("worktree ")) path = line.slice("worktree ".length);
    else if (line.startsWith("branch ") && path) {
      map.set(path, line.slice("branch refs/heads/".length));
    }
  }
  return map;
}

async function main(): Promise<void> {
  const trees = await worktrees();
  const probe = new PortHealthProbe({
    connect: createNetConnector(),
    now: () => Date.now(),
    setTimer: (fn, ms) => setTimeout(fn, ms),
    clearTimer: (h) => clearTimeout(h as NodeJS.Timeout),
  });

  let seen = 0;
  const snapshot = await new Promise<PortsSnapshotDTO>((resolve) => {
    const service = new PortsService({
      exec: (cmd, args, cwd, timeoutMs) => execRun(cmd, args, cwd, timeoutMs),
      probe,
      listWorktreePaths: () => [...trees.keys()],
      listWorktreeBranches: () => trees,
      // In-memory: a recording must never write the real history store.
      loadHistory: () => ({ entries: [] }),
      saveHistory: () => {},
      listSessionRoots: () => new Map(),
      tailnetAddress: () => null,
      onSnapshot: (s) => {
        if (++seen < WANT) return;
        service.stop();
        resolve(s);
      },
      now: () => Date.now(),
      setTimer: (fn, ms) => setInterval(fn, ms),
      clearTimer: (h) => clearInterval(h as NodeJS.Timeout),
    });
    // 0 -> 1 watchers arms the timer AND runs an immediate scan.
    service.setWatchers(1);
  });

  // `console.log`, not `stdout.write` + `process.exit`: exiting immediately
  // after a write truncates the pipe.
  console.log(JSON.stringify(snapshot, null, 2));
}

void main().then(
  () => {
    // The health probe and scan timer are disarmed by `service.stop()`; nothing
    // else holds the loop, so let node exit on its own rather than truncating.
    process.exitCode = 0;
  },
  (err) => {
    console.error(err);
    process.exitCode = 1;
  },
);
