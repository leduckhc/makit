import assert from "node:assert/strict";
import { test } from "node:test";

import {
  KILL_GRACE_MS,
  STARTED_AT_TOLERANCE_MS,
  classifyKillTarget,
  type KillGuards,
} from "./kill.js";
import type { PortDTO, PortKillTarget } from "../protocol.js";

const TARGET: PortKillTarget = {
  address: "127.0.0.1",
  port: 5173,
  pid: 48211,
  startedAt: 1_000,
};

/** A listener matching {@link TARGET}, owned by a worktree. */
function listener(overrides: Partial<PortDTO> = {}): PortDTO {
  return {
    key: "48211:127.0.0.1:5173",
    port: 5173,
    address: "127.0.0.1",
    reach: "loopback",
    pid: 48211,
    command: "node vite --port 5173",
    startedAt: 1_000,
    worktreePath: "/repo/wt-a",
    ...overrides,
  };
}

const GUARDS: KillGuards = {
  serverPid: 900,
  serverAncestors: new Set([800, 1]),
  sessionRoots: new Set([700]),
};

const ok = { scanOk: true };

test("KILL_GRACE_MS is 2000 — the SIGTERM→SIGKILL window", () => {
  assert.equal(KILL_GRACE_MS, 2_000);
});

test("a worktree-owned matched tuple is signalled", () => {
  const decision = classifyKillTarget(TARGET, { ...ok, ports: [listener()] }, GUARDS);
  assert.deepEqual(decision, { signal: true, pid: 48211 });
});

// ── R1 ─────────────────────────────────────────────────────────────────────
test("R1: a FAILED fresh scan refuses — it never falls back to a cache", () => {
  // The mutation this bites: reading the ≤4 s cached snapshot when `lsof` is
  // unavailable would signal a pid nobody re-verified.
  const decision = classifyKillTarget(
    TARGET,
    { scanOk: false, ports: [listener()] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "scan_unavailable" });
});

// ── R2 ─────────────────────────────────────────────────────────────────────
test("R2: nothing at (address, port) → not_found, no signal", () => {
  const decision = classifyKillTarget(TARGET, { ...ok, ports: [] }, GUARDS);
  assert.deepEqual(decision, { signal: false, outcome: "not_found" });
});

test("R2: the SAME port on another address is not a match", () => {
  const decision = classifyKillTarget(
    TARGET,
    { ...ok, ports: [listener({ address: "0.0.0.0", key: "48211:0.0.0.0:5173" })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "not_found" });
});

// ── R3 ─────────────────────────────────────────────────────────────────────
test("R3: a RECYCLED pid on the same endpoint → identity_mismatch", () => {
  const decision = classifyKillTarget(
    TARGET,
    { ...ok, ports: [listener({ pid: 51002 })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "identity_mismatch" });
});

test("R3: the SAME process re-scanned still matches despite startedAt jitter", () => {
  // `startedAt` is derived (`now - etime`) at one-second granularity, so it moves
  // between scans for an untouched process. Exact equality here refused every
  // real kill — the bug the real-listener acceptance test caught.
  for (const drift of [-999, -1, 0, 1, 999, STARTED_AT_TOLERANCE_MS]) {
    const decision = classifyKillTarget(
      TARGET,
      { ...ok, ports: [listener({ startedAt: TARGET.startedAt + drift })] },
      GUARDS,
    );
    assert.deepEqual(decision, { signal: true, pid: 48211 }, `drift ${drift} must still match`);
  }
});

test("R3: a RESTARTED process (same pid, new startedAt) → identity_mismatch", () => {
  const decision = classifyKillTarget(
    TARGET,
    { ...ok, ports: [listener({ startedAt: TARGET.startedAt + 60_000 })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "identity_mismatch" });
});

test("R3: a listener whose startedAt is UNKNOWN can never be verified", () => {
  const decision = classifyKillTarget(
    TARGET,
    { ...ok, ports: [listener({ startedAt: undefined })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "identity_mismatch" });
});

// ── R4 ─────────────────────────────────────────────────────────────────────
test("R4: an unowned system listener → not_owned", () => {
  const decision = classifyKillTarget(
    TARGET,
    { ...ok, ports: [listener({ worktreePath: undefined, command: "/usr/sbin/sshd" })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "not_owned" });
});

test("R4: a SPEC-42 orphan is killable even though it is unowned", () => {
  // Reclaiming an orphan is the point of the feature (§6): its worktree is gone,
  // so `worktreePath` is absent by definition and only the annotation proves it
  // was ever a dev server of ours.
  const decision = classifyKillTarget(
    TARGET,
    {
      ...ok,
      ports: [
        listener({
          worktreePath: undefined,
          orphan: { formerBranch: "gone/branch", formerWorktreePath: "/repo/gone" },
        }),
      ],
    },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: true, pid: 48211 });
});

// ── R5–R7 ──────────────────────────────────────────────────────────────────
test("R5: pid 1 is never signalled, even when attributed to a worktree", () => {
  const decision = classifyKillTarget(
    { ...TARGET, pid: 1 },
    { ...ok, ports: [listener({ pid: 1 })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "refused_protected" });
});

test("R6: makit's own server pid is refused", () => {
  const decision = classifyKillTarget(
    { ...TARGET, pid: GUARDS.serverPid },
    { ...ok, ports: [listener({ pid: GUARDS.serverPid })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "refused_self" });
});

test("R6: an ANCESTOR of the server pid is refused (killing it kills us)", () => {
  const decision = classifyKillTarget(
    { ...TARGET, pid: 800 },
    { ...ok, ports: [listener({ pid: 800 })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "refused_self" });
});

test("R7: a session's agent root is refused — that is session.kill's job", () => {
  const decision = classifyKillTarget(
    { ...TARGET, pid: 700 },
    { ...ok, ports: [listener({ pid: 700 })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "refused_session" });
});

test("the pid checks bind to the MATCHED listener, not the client's claim", () => {
  // A client that lies about the pid must not be able to route the refusal
  // checks around the real process: the tuple has to match first (R3).
  const decision = classifyKillTarget(
    { ...TARGET, pid: 48211 },
    { ...ok, ports: [listener({ pid: 1 })] },
    GUARDS,
  );
  assert.deepEqual(decision, { signal: false, outcome: "identity_mismatch" });
});
