/**
 * U2 (SPEC-46 P2) — `makit ask <id> MSG`: put a question to a session and print
 * only the answer.
 *
 * This is the cross-harness delegation verb: one agent asks another ("ask the
 * codex session what it decided about the migration") and gets a string back, not
 * a transcript. Which means the exit code carries the whole risk — D8's note is
 * exactly this case: *"an agent shelling out to `makit ask … --wait` would hang
 * forever on an approval it cannot see."* So a blocked turn must still exit
 * `10`/`11` rather than look like an answer that never came.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseAskArgs, runAsk } from "./ask.js";
import { EXIT_APPROVAL, EXIT_ERROR } from "./wait.js";
import { startStubWss, type StubWss } from "../../test/support/stub_wss.js";
import { withCliHome, captureCli } from "../../test/support/cli_home.js";

const SID = "s1";
const SESSION = {
  id: SID,
  projectId: "p1",
  agent: "pi",
  title: "t",
  status: "idle",
  lastActivityAt: 1,
};

const statusEvent = (seq: number, status: string) => ({
  seq,
  sessionId: SID,
  ts: seq,
  kind: "session.status",
  payload: { status },
});

const messageEvent = (seq: number, text: string) => ({
  seq,
  sessionId: SID,
  ts: seq,
  kind: "agent.message",
  payload: { text },
});

async function ask(
  argv: string[],
  script: Record<string, unknown>[],
  status = "idle",
  opts: { refuse?: string } = {},
): Promise<{ out: string; err: string; code: number; cmds: Record<string, unknown>[] }> {
  const cmds: Record<string, unknown>[] = [];
  let stub: StubWss | undefined;
  let captured = { out: "", err: "", code: 0 };
  try {
    stub = await startStubWss({
      acceptBearer: "CACHED",
      sessions: [{ ...SESSION, status }],
      onCmd: (m) => {
        cmds.push(m);
        if (opts.refuse !== undefined && m.kind === "send.message") return { __err: opts.refuse };
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
        await runAsk([...argv, "--port", String(port)]);
      });
    });
  } finally {
    await stub?.close();
  }
  return { ...captured, cmds };
}

test("parseAskArgs: id, message and the wait knobs", () => {
  const a = parseAskArgs([SID, "-m", "what did you decide?", "--timeout", "30"]);
  assert.equal(a.sessionId, SID);
  assert.equal(a.message, "what did you decide?");
  assert.equal(a.timeoutMs, 30_000);
});

test("the message may be positional, so an agent can write it the obvious way", () => {
  const a = parseAskArgs([SID, "what did you decide?"]);
  assert.equal(a.sessionId, SID);
  assert.equal(a.message, "what did you decide?");
});

test("a missing id or message is a usage error", async () => {
  const r = await captureCli(async () => {
    await runAsk([SID]);
  });
  assert.equal(r.code, 2);
});

test("it prints ONLY the final answer, not the turn around it", async () => {
  const r = await ask([SID, "-m", "what did you decide?"], [
    statusEvent(1, "running"),
    messageEvent(2, "an interim thought"),
    messageEvent(3, "we keep the down path"),
    statusEvent(4, "idle"),
  ]);
  assert.equal(r.code, 0, r.err);
  assert.equal(r.out, "we keep the down path\n", "the last agent.message, and nothing else");
});

test("the question is sent as a message to the named session", async () => {
  const r = await ask([SID, "-m", "hello"], [statusEvent(1, "running"), statusEvent(2, "idle")]);
  const msg = r.cmds.find((c) => c.kind === "send.message")!;
  assert.equal(msg.sessionId, SID);
  assert.equal(msg.text, "hello");
});

test("a turn that answers nothing is not silently an empty success", async () => {
  const r = await ask([SID, "-m", "hello"], [statusEvent(1, "running"), statusEvent(2, "idle")]);
  assert.notEqual(r.code, 0);
  assert.match(r.err, /no answer|nothing/i);
});

test("blocked on an approval exits 10 — the hang D8 warns about", async () => {
  const r = await ask([SID, "-m", "rm -rf build"], [
    statusEvent(1, "running"),
    statusEvent(2, "awaiting-approval"),
  ]);
  assert.equal(r.code, EXIT_APPROVAL);
  assert.equal(r.out, "", "a blocked turn prints no answer");
});

test("a failed turn exits 20, and does not print a partial reply as the answer", async () => {
  const r = await ask([SID, "-m", "hello"], [
    statusEvent(1, "running"),
    messageEvent(2, "I was about to say"),
    { seq: 3, sessionId: SID, ts: 3, kind: "session.error", payload: { message: "the model refused" } },
  ]);
  assert.equal(r.code, EXIT_ERROR);
  assert.equal(r.out, "");
});

test("--json emits the answer as the wire's own event, for jq", async () => {
  const r = await ask([SID, "-m", "hello", "--json"], [
    statusEvent(1, "running"),
    messageEvent(2, "the answer"),
    statusEvent(3, "idle"),
  ]);
  assert.deepEqual(JSON.parse(r.out.trim()), messageEvent(2, "the answer"));
});

test("a session already blocked reports it instead of hanging (the docstring's own promise)", async () => {
  // `ask` hard-coded `initialStatus: "idle"` and never looked at the real status, so
  // a queued message could not start a turn, no running→non-running edge ever came,
  // and — with no default timeout — `ask` hung. That is verbatim the failure D8 warns
  // about for this verb: "an agent shelling out to `makit ask … --wait` would hang
  // forever on an approval it cannot see." `wait` checks the snapshot; `ask` must too.
  const r = await ask([SID, "-m", "hello", "--timeout", "1"], [], "awaiting-approval");
  assert.equal(r.code, EXIT_APPROVAL);
  assert.equal(r.out, "", "and prints no answer");
});

test("a session that has already exited is reported, not waited on", async () => {
  const r = await ask([SID, "-m", "hello", "--timeout", "1"], [], "exited");
  assert.equal(r.code, 21);
});

test("a refused send.message exits 1 with a sentence, and does not hang", async () => {
  // The refusal arrives *after* the wait has been armed, so the outcome promise
  // is left orphaned: no turn will ever start, so the edge never fires. Unless
  // the failure closes the socket, `ask` waits forever on a question the server
  // already declined — D8's named hazard for this exact verb.
  const r = await ask([SID, "-m", "hello"], [], "idle", { refuse: "queue is full" });
  assert.equal(r.code, 1);
  assert.match(r.err, /queue is full/);
  assert.doesNotMatch(r.err, /at .*\.ts:/, "a refusal must not print a stack trace");
});
