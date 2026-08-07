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
import { PortsService, SCAN_INTERVAL_MS } from "../src/ports/service.js";
import { PortHealthProbe, createNetConnector } from "../src/ports/health.js";
import { run as execRun } from "../src/git.js";
import type { PortsSnapshotDTO } from "../src/protocol.js";

const REPO = process.argv[2] ?? process.cwd();
/// How many publications to wait for. Health is stale-while-revalidate (spec D3):
/// the first scan carries socket facts only and the probe verdict lands on a later
/// tick, so a recording of the health pills must wait for it.
///
/// This is a TARGET, not a requirement — see `DEADLINE_MS`. A quiet machine may
/// publish once and then dedup every later scan, so the capture settles for the
/// freshest snapshot it holds instead of blocking on a change that never comes.
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

  // A publication is NOT guaranteed per tick: the service dedups on an unchanged
  // projection, so on a quiet machine only the first scan ever calls `onSnapshot`.
  // Waiting for `WANT` publications unconditionally would leave the armed scan
  // interval running forever. Every exit path below is therefore bounded.
  //
  // The window must outlast the publications we actually want: the first scan is
  // immediate, each later one is a tick apart, so the WANT-th lands at about
  // `(WANT - 1) * SCAN_INTERVAL_MS`. One extra tick covers scan + probe latency.
  const DEADLINE_MS = WANT * SCAN_INTERVAL_MS;

  let seen = 0;
  let lastSnapshot: PortsSnapshotDTO | null = null;
  const snapshot = await new Promise<PortsSnapshotDTO>((resolve, reject) => {
    let deadlineHandle: NodeJS.Timeout | null = null;
    // Guards against the double-settle when a publication and the deadline race.
    let done = false;
    const finish = (s: PortsSnapshotDTO) => {
      if (done) return;
      done = true;
      if (deadlineHandle) clearTimeout(deadlineHandle);
      service.stop();
      resolve(s);
    };
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
        lastSnapshot = s;
        seen++;
        // Nothing is listening, so there is no pending health verdict to wait
        // for and no later scan that could differ from this one. Waiting for
        // `WANT` here is what used to hang the tool.
        if (seen === 1 && s.ports.length === 0) return finish(s);
        if (seen < WANT) return;
        finish(s);
      },
      now: () => Date.now(),
      setTimer: (fn, ms) => setInterval(fn, ms),
      clearTimer: (h) => clearInterval(h as NodeJS.Timeout),
    });
    // 0 -> 1 watchers arms the timer AND runs an immediate scan.
    service.setWatchers(1);
    // The steady state is "scanned fine, nothing changed since": settle for the
    // freshest snapshot we hold rather than waiting for a change that will not
    // come. `cachedSnapshot()` is the same value the service hands new watchers.
    deadlineHandle = setTimeout(() => {
      const fallback = lastSnapshot ?? service.cachedSnapshot() ?? null;
      if (fallback) {
        console.error(
          `capture: settled after ${DEADLINE_MS}ms with ${seen} publication(s) (wanted ${WANT}); ` +
            `health pills may still read "checking".`,
        );
        finish(fallback);
        return;
      }
      // No scan ever completed — emitting a snapshot here would be a fiction.
      done = true;
      service.stop();
      reject(
        new Error(
          `capture: no ports.snapshot within ${DEADLINE_MS}ms (is \`lsof\` available?)`,
        ),
      );
    }, DEADLINE_MS);
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
