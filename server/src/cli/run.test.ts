/**
 * T17 (SPEC-cli-as-client) — `makit run`: `new` + `wait` + print, as one command.
 *
 * This is the shape a git hook, a CI job, or an agent shelling out actually
 * wants: start the work, block until something happens, and let the **exit code**
 * say what happened (D8). The point of composing rather than reimplementing is
 * that `run` inherits `new`'s worktree rule (D15) and `wait`'s edge trigger, so
 * the `new + send + wait` trap — `send.message` acks before promotion, so a naive
 * wait would exit `0` having waited for nothing — cannot reappear here.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseRunArgs, runRun } from "./run.js";
import { EXIT_APPROVAL, EXIT_ERROR } from "./wait.js";
import { startStubWss, type StubWss } from "../../test/support/stub_wss.js";
import { withCliHome, captureCli } from "../../test/support/cli_home.js";

const PROJECT = { id: "p1", name: "makit", path: "/tmp/repo", pinned: false, lastActivityAt: 0 };
const DRAFT = {
  id: "child",
  projectId: "p1",
  agent: "pi",
  title: "t",
  status: "idle",
  lastActivityAt: 1,
};

const statusEvent = (seq: number, status: string) => ({
  seq,
  sessionId: "child",
  ts: seq,
  kind: "session.status",
  payload: { status },
});

const messageEvent = (seq: number, text: string) => ({
  seq,
  sessionId: "child",
  ts: seq,
  kind: "agent.message",
  payload: { text },
});

/**
 * Run `makit run` against a stub, scripting the child session's events. Timers
 * push them, so the run promise is awaited immediately (an unawaited
 * `process.exit` throw would be an unhandled rejection and fail the file).
 */
async function runWith(
  argv: string[],
  script: Record<string, unknown>[],
  opts: { refuse?: { kind: string; message: string } } = {},
): Promise<{ out: string; err: string; code: number; cmds: Record<string, unknown>[] }> {
  const cmds: Record<string, unknown>[] = [];
  let stub: StubWss | undefined;
  let captured = { out: "", err: "", code: 0 };
  try {
    stub = await startStubWss({
      acceptBearer: "CACHED",
      projects: [PROJECT],
      sessions: [DRAFT],
      onCmd: (m) => {
        cmds.push(m);
        if (opts.refuse && m.kind === opts.refuse.kind) return { __err: opts.refuse.message };
        if (m.kind === "worktree.create") return { path: "/tmp/repo-wt/x", branch: "x" };
        if (m.kind === "session.spawn") return { sessionId: "child" };
        return {};
      },
      // Live events go out the moment the client subscribes, in order — never on
      // a fixed timer, which races the connect and on a loaded runner lands the
      // whole script before the subscription exists.
      onSub: () => {
        for (const ev of script) stub!.push(ev);
      },
    });
    const port = stub.port;
    await withCliHome(async () => {
      captured = await captureCli(async () => {
        await runRun([...argv, "--port", String(port)]);
      });
    });
  } finally {
    await stub?.close();
  }
  return { ...captured, cmds };
}

test("parseRunArgs: takes new's flags plus wait's", () => {
  const a = parseRunArgs(["-m", "fix it", "--agent", "codex", "--timeout", "30", "--for", "idle"]);
  assert.equal(a.message, "fix it");
  assert.equal(a.agent, "codex");
  assert.equal(a.timeoutMs, 30_000);
  assert.equal(a.forWhat, "idle");
});

test("run without a message is a usage error — there would be nothing to wait for", async () => {
  const r = await captureCli(async () => {
    await runRun([]);
  });
  assert.equal(r.code, 2);
});

test("it creates the session, sends the message, and exits 0 on the completed turn", async () => {
  const r = await runWith(["-m", "fix the migration"], [statusEvent(1, "running"), statusEvent(2, "idle")]);
  assert.equal(r.code, 0, r.err);
  assert.deepEqual(
    r.cmds.map((c) => c.kind),
    ["worktree.create", "session.spawn", "send.message"],
  );
});

test("the agent's reply is printed", async () => {
  const r = await runWith(
    ["-m", "hello"],
    [statusEvent(1, "running"), messageEvent(2, "done — the migration is idempotent"), statusEvent(3, "idle")],
  );
  assert.match(r.out, /the migration is idempotent/);
});

test("the exit code comes from the wait phase: blocked on approval is 10, not 0", async () => {
  const r = await runWith(["-m", "rm -rf build"], [statusEvent(1, "running"), statusEvent(2, "awaiting-approval")]);
  assert.equal(r.code, EXIT_APPROVAL);
});

test("a failed turn propagates 20 even though the session settles idle after it", async () => {
  const r = await runWith(
    ["-m", "hello"],
    [
      statusEvent(1, "running"),
      { seq: 2, sessionId: "child", ts: 2, kind: "session.error", payload: { message: "the model refused" } },
      statusEvent(3, "idle"),
    ],
  );
  assert.equal(r.code, EXIT_ERROR);
});

test("--json streams the wire: one event per line, and the session id first", async () => {
  const r = await runWith(
    ["-m", "hello", "--json"],
    [statusEvent(1, "running"), messageEvent(2, "hi"), statusEvent(3, "idle")],
  );
  const lines = r.out.trimEnd().split("\n").map((l) => JSON.parse(l));
  assert.deepEqual(lines[0], { sessionId: "child" });
  assert.equal(lines[1].kind, "session.status");
  assert.deepEqual(lines[2], messageEvent(2, "hi"));
});

// ---------------------------------------------------------------------------
// A refusal is a sentence and an exit code — never a stack trace or a hang
//
// `run` composes two commands that the server can refuse: the D9 depth/fan-out
// bound refuses `session.spawn`, and a full queue or a dead session refuses
// `send.message`. Both are the *expected* answers to a confused agent's retry
// loop, so both have to unwind the way `new` does: one sentence, exit 1, socket
// closed. An escaping rejection instead prints a stack trace and leaves the
// WebSocket open, which keeps the event loop alive — the run never exits at all.
// ---------------------------------------------------------------------------

test("a refused session.spawn (the D9 bound) exits 1 with the server's sentence", async () => {
  const r = await runWith(["-m", "hello"], [], {
    refuse: { kind: "session.spawn", message: "session s1 already has 4 live children" },
  });
  assert.equal(r.code, 1);
  assert.match(r.err, /already has 4 live children/);
  assert.doesNotMatch(r.err, /at .*\.ts:/, "a refusal must not print a stack trace");
});

test("a refused send.message exits 1 with the server's sentence", async () => {
  const r = await runWith(["-m", "hello"], [], {
    refuse: { kind: "send.message", message: "session child is not accepting messages" },
  });
  assert.equal(r.code, 1);
  assert.match(r.err, /not accepting messages/);
});
