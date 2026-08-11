/**
 * SPEC-46 shared-contract guard.
 *
 * This file exists because SPEC-46 is implemented by several parallel workstreams
 * that all depend on the same vocabulary: the lineage fields on the wire (D10),
 * the capability vocabulary (D2/D3/D17), and the one additive control verb (D2).
 * Freezing it here means a workstream that changes the shared shape breaks a test
 * rather than silently breaking a sibling.
 *
 * Everything asserted here is deliberately *cheap and structural* — the
 * behavioural tests (who may dispatch what, who receives which events) live with
 * the code that enforces them.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { CONTROL_VERBS, decodeRequest } from "../../src/daemon/protocol.js";
import { hasCap, isAgentScoped, isFullAccess, type Principal } from "../../src/ws/principal.js";

// ---------------------------------------------------------------------------
// D2 — the CLI's own credential is minted over the control socket
// ---------------------------------------------------------------------------

test("SPEC-46 D2: cli.grant is a control verb, and the codec accepts it", () => {
  assert.ok(
    (CONTROL_VERBS as readonly string[]).includes("cli.grant"),
    "cli.grant must be in CONTROL_VERBS — the verb list is the real guard in decodeRequest",
  );
  const decoded = decodeRequest(JSON.stringify({ id: "1", verb: "cli.grant" }));
  assert.notEqual(decoded, null, "decodeRequest rejected cli.grant");
  assert.equal(decoded!.verb, "cli.grant");
});

test("SPEC-46 D1: the frozen lifecycle verbs are still there, unrepurposed", () => {
  // D1 permits *adding* a verb and forbids repurposing one. If a SPEC-46
  // workstream ever grows a session verb here instead of on WSS, this fails.
  for (const frozen of [
    "status",
    "pair.mint",
    "pair.current",
    "devices.list",
    "devices.revoke",
    "sessions.list",
    "server.stop",
    "logs.tail",
    "logs.cancel",
  ]) {
    assert.ok((CONTROL_VERBS as readonly string[]).includes(frozen), `${frozen} disappeared`);
  }
  assert.equal(
    CONTROL_VERBS.length,
    10,
    "a verb was added to the control socket — SPEC-46 D1 allows exactly one (cli.grant); " +
      "every session verb belongs on WSS",
  );
});

// ---------------------------------------------------------------------------
// D17 — capability semantics, including the two that are easy to get wrong
// ---------------------------------------------------------------------------

const phone: Principal = { deviceId: "d1", label: "iPhone" };
const cli: Principal = { deviceId: "d2", label: "cli@host", caps: ["client"] };
const agent: Principal = {
  deviceId: "sess-1",
  label: "agent@sess-1",
  caps: ["read", "send", "spawn"],
  sessionId: "sess-1",
};
const revoked: Principal = { deviceId: "d3", label: "nothing", caps: [] };

test("SPEC-46 D17: absent caps means FULL access (every phone paired before SPEC-46)", () => {
  assert.equal(isFullAccess(phone), true);
  assert.equal(hasCap(phone, "spawn"), true);
  // An unauthed socket has no principal at all; callers must not read that as deny.
  assert.equal(isFullAccess(undefined), true);
});

test("SPEC-46 D17: an EMPTY caps array is a revocation, not full access", () => {
  // The dangerous reading is `!caps?.length` — that would turn a credential
  // explicitly stripped of every capability into an unrestricted one.
  assert.equal(isFullAccess(revoked), false);
  assert.equal(hasCap(revoked, "read"), false);
  assert.equal(hasCap(revoked, "client"), false);
});

test("SPEC-46 D17: a capability set grants exactly what it lists", () => {
  assert.equal(hasCap(cli, "client"), true);
  assert.equal(hasCap(cli, "spawn"), false);
  assert.equal(hasCap(agent, "spawn"), true);
  assert.equal(hasCap(agent, "client"), false);
});

test("SPEC-46 D3/D13(c): only a session-scoped token is agent-scoped", () => {
  // D13(c) refuses an `srv.response` from an agent, and `--yolo` is human-only:
  // both key off exactly this predicate, so its edges are contract.
  assert.equal(isAgentScoped(agent), true);
  assert.equal(isAgentScoped(cli), false);
  assert.equal(isAgentScoped(phone), false);
  assert.equal(isAgentScoped(undefined), false);
});
