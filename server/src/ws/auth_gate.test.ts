/**
 * AuthGate principal tests (SPEC-cli-as-client T2/T3).
 *
 * A successful `hello` must leave a {@link Principal} on the client — the
 * subject the router and fanout gate read. An unknown bearer must still close
 * 4401 exactly as before, so widening the return value cannot open the door.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { AuthGate, type AuthRegistry, type AuthSessionTokens } from "./auth_gate.js";
import type { Principal } from "./principal.js";
import type { WsClient } from "./client.js";
import type { Envelope } from "../protocol.js";
import { SessionTokenStore } from "./session_tokens.js";

interface Frame {
  t: string;
  [k: string]: unknown;
}

function fakeClient(): WsClient & { frames: Frame[]; closed?: { code: number } } {
  const frames: Frame[] = [];
  return {
    frames,
    send(frame) {
      frames.push(frame as Frame);
    },
    close(code) {
      (this as { closed?: { code: number } }).closed = { code };
    },
    subscribed: new Set<string>(),
    authed: false,
    watchingMetrics: false,
    watchingDocs: false,
    watchingPorts: false,
    isLocal: false,
  };
}

const hello = (bearer: string): Envelope => ({ v: 1, t: "hello", id: "h1", bearer }) as Envelope;

test("a successful bearer hello sets the client principal with deviceId/label/caps", () => {
  const registry: AuthRegistry = {
    authenticate: (b) =>
      b === "good" ? { id: "dev-1", label: "cli@box", caps: ["client"] } : null,
    consumePairToken: () => null,
  };
  const client = fakeClient();
  const gate = new AuthGate({ registry, onAuthenticated: () => {} });

  gate.handleHello(client, hello("good"));

  assert.equal(client.authed, true);
  assert.deepEqual(client.principal, {
    deviceId: "dev-1",
    label: "cli@box",
    caps: ["client"],
  });
});

test("a device with no caps yields a principal with caps undefined (full access)", () => {
  const registry: AuthRegistry = {
    authenticate: () => ({ id: "phone-1", label: "phone" }),
    consumePairToken: () => null,
  };
  const client = fakeClient();
  new AuthGate({ registry, onAuthenticated: () => {} }).handleHello(client, hello("phone-tok"));

  assert.equal(client.principal?.deviceId, "phone-1");
  assert.equal(client.principal?.caps, undefined);
});

test("an unknown bearer still closes 4401 and sets no principal", () => {
  const registry: AuthRegistry = {
    authenticate: () => null,
    consumePairToken: () => null,
  };
  const client = fakeClient();
  new AuthGate({ registry, onAuthenticated: () => {} }).handleHello(client, hello("bad"));

  assert.equal(client.authed, false);
  assert.equal(client.principal, undefined);
  assert.equal(client.closed?.code, 4401);
});

test("a session-token bearer authenticates via the store when the registry misses (C2)", () => {
  const registry: AuthRegistry = { authenticate: () => null, consumePairToken: () => null };
  const store = new SessionTokenStore();
  const token = store.mint("sess-A");
  const client = fakeClient();

  new AuthGate({ registry, onAuthenticated: () => {}, sessionTokens: store }).handleHello(
    client,
    hello(token),
  );

  assert.equal(client.authed, true);
  assert.equal(client.principal?.sessionId, "sess-A");
  assert.deepEqual(client.principal?.caps, ["read", "send", "spawn"]);
});

// ---------------------------------------------------------------------------
// An incomplete agent principal is rejected at the boundary
//
// `isFullAccess` reads a missing `caps` as FULL access and `isAgentScoped` reads
// a missing `sessionId` as "not an agent". So an `AuthSessionTokens`
// implementation that returned a principal missing either field would not fail
// closed — it would silently promote the agent to human-level authority, past
// the command capability map and every read gate. The real store always sets
// both; the interface it satisfies does not require it, so the invariant belongs
// here rather than in every future implementer's memory.
// ---------------------------------------------------------------------------

/** A token store that authenticates but returns an under-specified principal. */
const partialStore = (principal: Principal): AuthSessionTokens => ({
  authenticate: () => principal,
});

test("an agent principal with no sessionId is rejected, not treated as full access", () => {
  const registry: AuthRegistry = { authenticate: () => null, consumePairToken: () => null };
  const client = fakeClient();

  new AuthGate({
    registry,
    onAuthenticated: () => {},
    sessionTokens: partialStore({ deviceId: "d", label: "agent:?", caps: ["read"] }),
  }).handleHello(client, hello("tok"));

  assert.equal(client.authed, false, "an unscoped agent credential must not authenticate");
  assert.equal(client.principal, undefined);
});

test("an agent principal with no caps is rejected, not treated as full access", () => {
  const registry: AuthRegistry = { authenticate: () => null, consumePairToken: () => null };
  const client = fakeClient();

  new AuthGate({
    registry,
    onAuthenticated: () => {},
    sessionTokens: partialStore({ deviceId: "d", label: "agent:s1", sessionId: "s1" }),
  }).handleHello(client, hello("tok"));

  assert.equal(client.authed, false, "caps-absent means FULL access, which an agent may never have");
  assert.equal(client.principal, undefined);
});

test("a well-formed agent principal still authenticates (the guard is not a wall)", () => {
  const registry: AuthRegistry = { authenticate: () => null, consumePairToken: () => null };
  const client = fakeClient();

  new AuthGate({
    registry,
    onAuthenticated: () => {},
    sessionTokens: partialStore({ deviceId: "d", label: "agent:s1", sessionId: "s1", caps: ["read"] }),
  }).handleHello(client, hello("tok"));

  assert.equal(client.authed, true);
  assert.equal(client.principal?.sessionId, "s1");
});
