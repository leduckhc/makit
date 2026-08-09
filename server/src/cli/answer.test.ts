/**
 * SPEC-46 U3 — `makit answer`: fill a session's pending `input` elicitation
 * with text from the terminal, the sibling of `makit approve`.
 *
 * Same client-only flow (`sub` → replayed `srv.request` → `srv.response`) and
 * same hang guard: with no pending prompt the verb exits non-zero rather than
 * awaiting a question that may already have been answered from the phone.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseAnswerArgs, runAnswer } from "./answer.js";
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

const input = (sessionId = SID): Record<string, unknown> => ({
  id: "srv-9",
  kind: "input",
  sessionId,
  title: "Which branch should I target?",
});

async function run(
  argv: string[],
  opts: { srvRequests?: Record<string, unknown>[] } = {},
): Promise<{ out: string; err: string; code: number; responses: Record<string, unknown>[] }> {
  const stub = await startStubWss({ acceptBearer: "CACHED", srvRequests: opts.srvRequests });
  try {
    const cap = await captureCli(() =>
      withCliHome(() => runAnswer([...argv, "--port", String(stub.port)])),
    );
    await settle(stub.responses);
    return { ...cap, responses: stub.responses };
  } finally {
    await stub.close();
  }
}

test("parseAnswerArgs: id then TEXT, joining an unquoted multi-word answer", () => {
  assert.equal(parseAnswerArgs([SID, "main"]).text, "main");
  const a = parseAnswerArgs([SID, "feature", "x"]);
  assert.equal(a.sessionId, SID);
  assert.equal(a.text, "feature x");
});

test("answer fills a pending input prompt with the given text", async () => {
  const r = await run([SID, "feature/x"], { srvRequests: [input()] });
  assert.equal(r.code, 0, r.err);
  assert.equal(r.responses.length, 1);
  const resp = r.responses[0]!;
  assert.equal(resp.t, "srv.response");
  assert.equal(resp.id, "srv-9");
  assert.equal(resp.kind, "input");
  assert.equal(resp.value, "feature/x");
});

test("a prompt for a session the CLI did not name is never answered (D13b, client side)", async () => {
  const r = await run([SID, "main"], { srvRequests: [input("s2")] });
  assert.notEqual(r.code, 0);
  assert.equal(r.responses.length, 0);
});

test("no pending prompt exits non-zero instead of hanging", async () => {
  const r = await run([SID, "main"], {});
  assert.notEqual(r.code, 0);
  assert.equal(r.responses.length, 0);
});

test("a missing id or text is a usage error (exit 2)", async () => {
  assert.equal((await run([])).code, 2);
  assert.equal((await run([SID])).code, 2);
});
