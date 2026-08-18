/**
 * SessionTokenStore tests (SPEC-cli-as-client T3 / contract C2).
 *
 * The per-session agent credential is in-memory ON PURPOSE: it must never be
 * written to `~/.makit/devices.json` (which persists on every mutation), or a
 * crash would leave a valid credential for a session that no longer exists, and
 * it would pollute `makit devices`. These tests pin that boundary.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { SessionTokenStore } from "./session_tokens.js";
import { DeviceRegistry } from "../pairing/registry.js";

test("a minted token authenticates as a session-scoped principal", () => {
  const store = new SessionTokenStore();
  const token = store.mint("sess-A");
  const principal = store.authenticate(token);

  assert.equal(principal?.sessionId, "sess-A");
  assert.deepEqual(principal?.caps, ["read", "send", "spawn"]);
});

test("an unknown token authenticates to null", () => {
  const store = new SessionTokenStore();
  assert.equal(store.authenticate("nope"), null);
});

test("after drop(), the session's token no longer authenticates", () => {
  const store = new SessionTokenStore();
  const token = store.mint("sess-A");
  store.drop("sess-A");
  assert.equal(store.authenticate(token), null);
});

test("re-minting a session drops the old token so only the newest is valid", () => {
  const store = new SessionTokenStore();
  const first = store.mint("sess-A");
  const second = store.mint("sess-A");
  assert.notEqual(first, second);
  assert.equal(store.authenticate(first), null);
  assert.equal(store.authenticate(second)?.sessionId, "sess-A");
});

test("a minted token never appears in the device registry and is not persisted", () => {
  const prev = process.env.MAKIT_HOME;
  const home = mkdtempSync(join(tmpdir(), "makit-sesstok-"));
  process.env.MAKIT_HOME = home;
  try {
    const registry = new DeviceRegistry();
    const store = new SessionTokenStore();
    const token = store.mint("sess-A");

    // Not a device: the registry cannot authenticate it, and it is in no list.
    assert.equal(registry.authenticate(token), null);
    assert.equal(registry.list().length, 0);
    // Nothing was written to disk by minting a session token.
    assert.equal(existsSync(join(home, "devices.json")), false);
  } finally {
    if (prev === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prev;
    rmSync(home, { recursive: true, force: true });
  }
});
