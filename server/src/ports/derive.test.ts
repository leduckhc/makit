import { test } from "node:test";
import assert from "node:assert/strict";

import { annotate, type AnnotateInput } from "./derive.js";
import { HISTORY_TTL_MS, type PortHistory } from "./history_store.js";
import type { ProcInfo } from "./proc.js";
import type { PortDTO } from "../protocol.js";

const NOW = 1_700_000_000_000;
const FRESH = NOW - 1000;

function proc(pid: number, ppid: number, command = "node"): ProcInfo {
  return { pid, ppid, command };
}

function unownedPort(pid: number, port: number): PortDTO {
  return { key: `${pid}:127.0.0.1:${port}`, port, address: "127.0.0.1", reach: "loopback", pid, command: "node" };
}

function ownedPort(pid: number, port: number, worktreePath: string): PortDTO {
  return { ...unownedPort(pid, port), worktreePath };
}

function base(overrides: Partial<AnnotateInput>): AnnotateInput {
  return {
    ports: [],
    cwds: new Map(),
    procs: new Map(),
    history: { entries: [] },
    activeWorktreePaths: [],
    resolveReal: (p) => p,
    now: NOW,
    ...overrides,
  };
}

test("an unowned port whose cwd matches a removed history path → orphan with branch + date", () => {
  const out = annotate(
    base({
      ports: [unownedPort(200, 5173)],
      cwds: new Map([[200, "/repo/wt-a"]]),
      procs: new Map([[200, proc(200, 1)]]),
      history: { entries: [{ worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: 0, lastSeen: FRESH }] },
      activeWorktreePaths: [], // wt-a is gone
    }),
  );
  assert.deepEqual(out[0]!.orphan, {
    formerWorktreePath: "/repo/wt-a",
    formerBranch: "feat/a",
    removedAt: FRESH,
  });
});

test("the SAME orphan with EMPTY history → no orphan, no fabricated date (D10)", () => {
  const out = annotate(
    base({
      ports: [unownedPort(200, 5173)],
      cwds: new Map([[200, "/repo/wt-a"]]),
      procs: new Map([[200, proc(200, 1)]]),
      history: { entries: [] },
      activeWorktreePaths: [],
    }),
  );
  assert.equal(out[0]!.orphan, undefined);
});

test("an orphan whose history entry recorded NO branch omits formerBranch (no zeroing)", () => {
  const out = annotate(
    base({
      ports: [unownedPort(200, 5173)],
      cwds: new Map([[200, "/repo/wt-a"]]),
      procs: new Map([[200, proc(200, 1)]]),
      history: { entries: [{ worktreePath: "/repo/wt-a", ports: [5173], firstSeen: 0, lastSeen: FRESH }] },
      activeWorktreePaths: [],
    }),
  );
  assert.deepEqual(out[0]!.orphan, { formerWorktreePath: "/repo/wt-a", removedAt: FRESH });
});

test("a history entry older than HISTORY_TTL_MS is ignored — no fabricated orphan", () => {
  const out = annotate(
    base({
      ports: [unownedPort(200, 5173)],
      cwds: new Map([[200, "/repo/wt-a"]]),
      procs: new Map([[200, proc(200, 1)]]),
      history: { entries: [{ worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: 0, lastSeen: NOW - HISTORY_TTL_MS - 1 }] },
      activeWorktreePaths: [],
    }),
  );
  assert.equal(out[0]!.orphan, undefined);
});

test("the orphan cwd is resolved via the ancestor walk when the listener's own cwd is unknown", () => {
  // Listener 200 has no cwd; its parent 100 sits in the removed worktree.
  const out = annotate(
    base({
      ports: [unownedPort(200, 5173)],
      cwds: new Map([[100, "/repo/wt-a"]]),
      procs: new Map([
        [200, proc(200, 100)],
        [100, proc(100, 1)],
      ]),
      history: { entries: [{ worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: 0, lastSeen: FRESH }] },
      activeWorktreePaths: [],
    }),
  );
  assert.equal(out[0]!.orphan?.formerWorktreePath, "/repo/wt-a");
});

test("an unowned system port matching nothing stays plain unowned", () => {
  const out = annotate(
    base({
      ports: [unownedPort(9, 5432)],
      cwds: new Map([[9, "/usr/lib/postgres"]]),
      procs: new Map([[9, proc(9, 1, "postgres")]]),
      history: { entries: [{ worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: 0, lastSeen: FRESH }] },
      activeWorktreePaths: [],
    }),
  );
  assert.equal(out[0]!.orphan, undefined);
  assert.equal(out[0]!.collision, undefined);
});

test("a still-active historical worktree is NOT an orphan match", () => {
  const out = annotate(
    base({
      ports: [unownedPort(200, 5173)],
      cwds: new Map([[200, "/repo/wt-a"]]),
      procs: new Map([[200, proc(200, 1)]]),
      history: { entries: [{ worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: 0, lastSeen: FRESH }] },
      activeWorktreePaths: ["/repo/wt-a"], // still active → not removed
    }),
  );
  assert.equal(out[0]!.orphan, undefined);
});

test("an owned port with a second active worktree in history → collision.withBranch", () => {
  const out = annotate(
    base({
      ports: [ownedPort(200, 5173, "/repo/wt-a")],
      cwds: new Map([[200, "/repo/wt-a"]]),
      procs: new Map([[200, proc(200, 1)]]),
      history: {
        entries: [
          { worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: 0, lastSeen: FRESH },
          { worktreePath: "/repo/wt-b", branch: "feat/b", ports: [5173], firstSeen: 0, lastSeen: FRESH },
        ],
      },
      activeWorktreePaths: ["/repo/wt-a", "/repo/wt-b"],
    }),
  );
  assert.deepEqual(out[0]!.collision, { withBranch: "feat/b", withWorktreePath: "/repo/wt-b" });
});

test("an owned port with a single owner in history → no collision", () => {
  const out = annotate(
    base({
      ports: [ownedPort(200, 5173, "/repo/wt-a")],
      cwds: new Map([[200, "/repo/wt-a"]]),
      procs: new Map([[200, proc(200, 1)]]),
      history: { entries: [{ worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: 0, lastSeen: FRESH }] },
      activeWorktreePaths: ["/repo/wt-a"],
    }),
  );
  assert.equal(out[0]!.collision, undefined);
});

test("a REMOVED rival worktree does NOT count as a collision (only still-active claimants)", () => {
  const out = annotate(
    base({
      ports: [ownedPort(200, 5173, "/repo/wt-a")],
      cwds: new Map([[200, "/repo/wt-a"]]),
      procs: new Map([[200, proc(200, 1)]]),
      history: {
        entries: [
          { worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: 0, lastSeen: FRESH },
          { worktreePath: "/repo/wt-b", branch: "feat/b", ports: [5173], firstSeen: 0, lastSeen: FRESH },
        ],
      },
      activeWorktreePaths: ["/repo/wt-a"], // wt-b is gone
    }),
  );
  assert.equal(out[0]!.collision, undefined);
});

test("annotate never mutates its inputs", () => {
  const ports = [unownedPort(200, 5173)];
  const history: PortHistory = {
    entries: [{ worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: 0, lastSeen: FRESH }],
  };
  const input = base({
    ports,
    cwds: new Map([[200, "/repo/wt-a"]]),
    procs: new Map([[200, proc(200, 1)]]),
    history,
    activeWorktreePaths: [],
  });
  const frozenPort = { ...ports[0] };
  annotate(input);
  assert.deepEqual(ports[0], frozenPort, "the input port object is untouched");
  assert.equal(ports[0]!.orphan, undefined, "no orphan mutated onto the input");
  assert.deepEqual(history.entries[0]!.ports, [5173], "history untouched");
});

test("annotate returns a fresh array, preserving order", () => {
  const ports = [unownedPort(200, 5173), ownedPort(300, 3000, "/repo/wt-a")];
  const out = annotate(base({ ports, procs: new Map(), cwds: new Map() }));
  assert.notEqual(out, ports);
  assert.deepEqual(out.map((p) => p.port), [5173, 3000]);
});
