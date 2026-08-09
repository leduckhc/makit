/**
 * T16 (SPEC-46) — `makit wait`: the exit code IS the automation contract (D8).
 *
 * The subtlety, and the reason this is edge-triggered: `send.message` **acks
 * before promotion** (`ws/commands/session.ts:128`), so a composed
 * `new + send + wait` would observe the session's pre-existing `idle` and exit
 * `0` having waited for nothing. So `wait` requires a `running` → non-running
 * **transition**, which is the same boundary the app's notification policy uses
 * (`notification_policy.dart:19`) rather than a second invented one.
 *
 * The other trap D8 records: **nothing in makit ever emits `status: "error"`**.
 * Adapters emit a `session.error` *event* and then settle **idle**, so exit `20`
 * must key off the event. A `wait` that keyed off the status would report a
 * failed turn as a clean success.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseWaitArgs, runWait, EXIT_APPROVAL, EXIT_INPUT, EXIT_ERROR, EXIT_EXITED, EXIT_TIMEOUT } from "./wait.js";
import { startStubWss, type StubWss } from "../../test/support/stub_wss.js";
import { withCliHome, captureCli } from "../../test/support/cli_home.js";

const SID = "s1";

const session = (status: string) => ({
  id: SID,
  projectId: "p1",
  agent: "pi",
  title: "t",
  status,
  lastActivityAt: 1,
});

const statusEvent = (seq: number, status: string) => ({
  seq,
  sessionId: SID,
  ts: seq,
  kind: "session.status",
  payload: { status },
});

const errorEvent = (seq: number, message: string) => ({
  seq,
  sessionId: SID,
  ts: seq,
  kind: "session.error",
  payload: { message },
});

/**
 * Run `makit wait` against a stub whose session starts in `status`, then feed it
 * `script` (events pushed once the client has subscribed). Nothing is ever
 * awaited that the stub does not send — a blocked session is by definition a
 * promise that never settles.
 */
async function waitWith(
  argv: string[],
  status: string,
  script: Record<string, unknown>[] = [],
): Promise<{ out: string; err: string; code: number }> {
  let stub: StubWss | undefined;
  let captured = { out: "", err: "", code: 0 };
  try {
    stub = await startStubWss({
      acceptBearer: "CACHED",
      sessions: [session(status)],
      onCmd: () => ({}),
    });
    const port = stub.port;
    await withCliHome(async () => {
      captured = await captureCli(async () => {
        // Scripted events are pushed from timers so the `runWait` promise is
        // awaited immediately: an unawaited rejection (a `process.exit` throw)
        // is an unhandled rejection, which fails the whole test file.
        script.forEach((ev, i) => setTimeout(() => stub!.push(ev), 15 * (i + 1)).unref());
        await runWait([SID, "--port", String(port), ...argv]);
      });
    });
  } finally {
    await stub?.close();
  }
  return captured;
}

// ---------------------------------------------------------------------------
// argv parsing
// ---------------------------------------------------------------------------

test("parseWaitArgs: session id, --for and --timeout", () => {
  const a = parseWaitArgs([SID, "--for", "approval", "--timeout", "30"]);
  assert.equal(a.sessionId, SID);
  assert.equal(a.forWhat, "approval");
  assert.equal(a.timeoutMs, 30_000);
});

test("parseWaitArgs: defaults to --for any and no timeout", () => {
  const a = parseWaitArgs([SID]);
  assert.equal(a.forWhat, "any");
  assert.equal(a.timeoutMs, undefined);
});

test("wait with no session id is a usage error", async () => {
  const r = await captureCli(async () => {
    await runWait([]);
  });
  assert.equal(r.code, 2);
});

// ---------------------------------------------------------------------------
// D8 — the running → non-running edge
// ---------------------------------------------------------------------------

test("a turn that runs and finishes exits 0", async () => {
  const r = await waitWith([], "idle", [statusEvent(1, "running"), statusEvent(2, "idle")]);
  assert.equal(r.code, 0, r.err);
});

test("an idle session does NOT exit 0 until a turn has actually run (the new+send+wait trap)", async () => {
  // Only an idle status arrives — no `running` was ever seen, so there was no
  // turn to complete. `wait` must keep waiting; `--timeout` is what ends it.
  const r = await waitWith(["--timeout", "1"], "idle", [statusEvent(1, "idle"), statusEvent(2, "idle")]);
  assert.equal(r.code, EXIT_TIMEOUT);
});

test("a session already running when wait starts still gets its completion", async () => {
  const r = await waitWith([], "running", [statusEvent(1, "idle")]);
  assert.equal(r.code, 0, r.err);
});

// ---------------------------------------------------------------------------
// blocked and failed outcomes
// ---------------------------------------------------------------------------

test("blocked on a tool approval exits 10", async () => {
  const r = await waitWith([], "running", [statusEvent(1, "awaiting-approval")]);
  assert.equal(r.code, EXIT_APPROVAL);
  assert.equal(EXIT_APPROVAL, 10);
});

test("blocked on an elicitation exits 11", async () => {
  const r = await waitWith([], "running", [statusEvent(1, "awaiting-input")]);
  assert.equal(r.code, EXIT_INPUT);
  assert.equal(EXIT_INPUT, 11);
});

test("a session already blocked when wait starts reports it immediately", async () => {
  // No edge is required here: it is already blocked on the human, and pretending
  // otherwise would hang a script on a question it cannot see.
  const r = await waitWith([], "awaiting-approval");
  assert.equal(r.code, EXIT_APPROVAL);
});

test("a session.error EVENT exits 20, even though the session then settles idle", async () => {
  const r = await waitWith([], "running", [errorEvent(1, "the model refused"), statusEvent(2, "idle")]);
  assert.equal(r.code, EXIT_ERROR);
  assert.equal(EXIT_ERROR, 20);
  assert.match(r.err, /the model refused/);
});

test("an exited agent exits 21", async () => {
  const r = await waitWith([], "running", [statusEvent(1, "exited")]);
  assert.equal(r.code, EXIT_EXITED);
  assert.equal(EXIT_EXITED, 21);
});

// ---------------------------------------------------------------------------
// --for narrows what ends the wait
// ---------------------------------------------------------------------------

test("--for idle waits through an approval instead of exiting on it", async () => {
  const r = await waitWith(["--for", "idle", "--timeout", "1"], "running", [statusEvent(1, "awaiting-approval")]);
  assert.equal(r.code, EXIT_TIMEOUT, "an approval is not what was asked for");
});

test("--for approval exits 10 on the prompt and ignores a completed turn", async () => {
  const r = await waitWith(["--for", "approval"], "running", [
    statusEvent(1, "idle"),
    statusEvent(2, "running"),
    statusEvent(3, "awaiting-approval"),
  ]);
  assert.equal(r.code, EXIT_APPROVAL);
});

test("--timeout is a distinct code, never confused with a completed turn", async () => {
  const r = await waitWith(["--timeout", "1"], "running");
  assert.equal(r.code, EXIT_TIMEOUT);
  assert.notEqual(EXIT_TIMEOUT, 0);
  assert.match(r.err, /timed out/i);
});
