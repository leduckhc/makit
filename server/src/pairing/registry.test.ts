/**
 * Pairing security tests (backlog B6).
 *
 * Each test runs against a fresh PINO_HOME temp dir so the on-disk
 * devices.json is isolated and cleaned up.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DeviceRegistry } from "./registry.js";

function withHome(fn: (home: string) => void | Promise<void>) {
  const prev = process.env.PINO_HOME;
  const home = mkdtempSync(join(tmpdir(), "pino-test-"));
  process.env.PINO_HOME = home;
  try {
    return fn(home);
  } finally {
    if (prev === undefined) delete process.env.PINO_HOME;
    else process.env.PINO_HOME = prev;
    rmSync(home, { recursive: true, force: true });
  }
}

test("pair token is single-use", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const token = reg.mintPairToken();
    assert.notEqual(reg.consumePairToken(token, "phone"), null);
    assert.equal(reg.consumePairToken(token, "phone"), null);
  }));

test("expired pair token is rejected", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const token = reg.mintPairToken(-1); // already expired
    assert.equal(reg.consumePairToken(token, "phone"), null);
  }));

test("unknown bearer does not authenticate", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    assert.equal(reg.authenticate("deadbeef"), null);
    // A real device still authenticates.
    const device = reg.consumePairToken(reg.mintPairToken(), "phone");
    assert.ok(device);
    assert.equal(reg.authenticate(device!.bearer)?.id, device!.id);
    assert.equal(reg.authenticate("nope"), null);
  }));

test("revoke removes the device and its bearer", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const device = reg.consumePairToken(reg.mintPairToken(), "phone");
    assert.ok(device);
    assert.equal(reg.revoke(device!.id), true);
    assert.equal(reg.list().length, 0);
    assert.equal(reg.authenticate(device!.bearer), null);
    assert.equal(reg.revoke(device!.id), false);
  }));

test("corrupt devices.json starts fresh without throwing", () =>
  withHome((home) => {
    mkdirSync(home, { recursive: true });
    writeFileSync(join(home, "devices.json"), "{ not valid json ]");
    let reg: DeviceRegistry;
    assert.doesNotThrow(() => {
      reg = new DeviceRegistry();
    });
    assert.equal(reg!.list().length, 0);
  }));

test("too many bad pair attempts trips a lockout", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const valid = reg.mintPairToken();
    for (let i = 0; i < 32; i++) {
      assert.equal(reg.consumePairToken("bad-token", "phone"), null);
    }
    // Even a valid token is refused while locked out.
    assert.equal(reg.consumePairToken(valid, "phone"), null);
  }));
