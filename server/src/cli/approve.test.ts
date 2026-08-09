/**
 * SPEC-46 U3 — `makit approve`: answer a session's pending `confirmAction` from
 * the terminal, so a session an agent started (nobody on a screen) can be
 * unblocked from the devbox shell that started it.
 *
 * The flow is client-only: `sub {sessionId}` makes the server replay the
 * session's pending `srv.request` (it already calls `replayPendingTo` right
 * after the `sub` ack), and the CLI answers it. Two locks are pinned here: a
 * `--deny` is an explicit `approved: false` (never silently the safe answer),
 * and a prompt for a session the CLI did not name is never answered — D13(b)
 * from the client side.
 *
 * The hang trap (AGENTS/DEVELOPMENT): `node --test` has no per-test timeout, so
 * the "no pending prompt" case must not `await` a promise that never settles.
 * The verb bounds its own wait and exits non-zero; the assertions read the
 * frames the stub actually received.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseApproveArgs, runApprove } from "./approve.js";
import { withCliHome, captureCli } from "../../test/support/cli_home.js";
import { startStubWss } from "../../test/support/stub_wss.js";

const SID = "s1";

/** Let the stub's message loop drain the in-flight `srv.response` (bounded). */
async function settle(responses: unknown[]): Promise<void> {
  const deadline = Date.now() + 300;
  while (responses.length === 0 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 5));
  }
}

const confirm = (sessionId = SID): Record<string, unknown> => ({
  id: "srv-1",
  kind: "confirmAction",
  sessionId,
  title: "Run rm -rf build?",
  message: "the agent wants to run a risky command",
  action: "bash",
});

async function run(
  argv: string[],
  opts: { srvRequests?: Record<string, unknown>[] } = {},
): Promise<{ out: string; err: string; code: number; responses: Record<string, unknown>[] }> {
  const stub = await startStubWss({ acceptBearer: "CACHED", srvRequests: opts.srvRequests });
  try {
    const cap = await captureCli(() =>
      withCliHome(() => runApprove([...argv, "--port", String(stub.port)])),
    );
    await settle(stub.responses);
    return { ...cap, responses: stub.responses };
  } finally {
    await stub.close();
  }
}

test("parseApproveArgs: id positional, --deny flag", () => {
  const a = parseApproveArgs([SID, "--deny"]);
  assert.equal(a.sessionId, SID);
  assert.equal(a.deny, true);
  assert.equal(parseApproveArgs([SID]).deny, false);
});

test("subscribing replays a pending confirmAction and approve answers approved: true", async () => {
  const r = await run([SID], { srvRequests: [confirm()] });
  assert.equal(r.code, 0, r.err);
  assert.equal(r.responses.length, 1);
  const resp = r.responses[0]!;
  assert.equal(resp.t, "srv.response");
  assert.equal(resp.id, "srv-1");
  assert.equal(resp.kind, "confirmAction");
  assert.equal(resp.approved, true);
});

test("--deny answers approved: false (an explicit user act, never the silent safe one)", async () => {
  const r = await run([SID, "--deny"], { srvRequests: [confirm()] });
  assert.equal(r.code, 0, r.err);
  assert.equal(r.responses[0]!.approved, false);
});

test("a prompt for a session the CLI did not name is never answered (D13b, client side)", async () => {
  const r = await run([SID], { srvRequests: [confirm("s2")] });
  assert.notEqual(r.code, 0);
  assert.equal(r.responses.length, 0, "nothing is answered for a session we did not subscribe to");
});

test("no pending prompt exits non-zero instead of hanging", async () => {
  const r = await run([SID], {});
  assert.notEqual(r.code, 0);
  assert.equal(r.responses.length, 0);
});

test("a missing id is a usage error (exit 2)", async () => {
  const r = await run([]);
  assert.equal(r.code, 2);
  assert.equal(r.responses.length, 0);
});
