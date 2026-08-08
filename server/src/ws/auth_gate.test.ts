/**
 * AuthGate principal tests (SPEC-46 T2/T3).
 *
 * A successful `hello` must leave a {@link Principal} on the client — the
 * subject the router and fanout gate read. An unknown bearer must still close
 * 4401 exactly as before, so widening the return value cannot open the door.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { AuthGate, type AuthRegistry } from "./auth_gate.js";
import type { WsClient } from "./client.js";
import type { Envelope } from "../protocol.js";

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
