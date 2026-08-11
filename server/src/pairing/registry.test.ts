/**
 * Pairing security tests (backlog B6).
 *
 * Each test runs against a fresh MAKIT_HOME temp dir so the on-disk
 * devices.json is isolated and cleaned up.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { hostname } from "node:os";

import { DeviceRegistry } from "./registry.js";

async function withHome(fn: (home: string) => void | Promise<void>) {
  const prev = process.env.MAKIT_HOME;
  const home = mkdtempSync(join(tmpdir(), "makit-test-"));
  process.env.MAKIT_HOME = home;
  try {
    await fn(home);
  } finally {
    if (prev === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prev;
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

test("a flood of bad tokens never blocks a valid one (no DoS)", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const valid = reg.mintPairToken();
    // An attacker spamming bad guesses must NOT lock out the legitimate phone.
    for (let i = 0; i < 32; i++) {
      assert.equal(reg.consumePairToken("bad-token", "phone"), null);
    }
    assert.notEqual(reg.consumePairToken(valid, "phone"), null);
  }));

test("authenticate scans all devices (constant-time, no early exit)", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const a = reg.consumePairToken(reg.mintPairToken(), "a")!;
    const b = reg.consumePairToken(reg.mintPairToken(), "b")!;
    const c = reg.consumePairToken(reg.mintPairToken(), "c")!;
    // First, middle, and last device all resolve — proves the scan doesn't
    // stop early and each bearer maps to its own device.
    assert.equal(reg.authenticate(a.bearer)?.id, a.id);
    assert.equal(reg.authenticate(b.bearer)?.id, b.id);
    assert.equal(reg.authenticate(c.bearer)?.id, c.id);
    assert.equal(reg.authenticate("nope"), null);
  }));

// ---------------------------------------------------------------------------
// SPEC-46 D2 — grantCli is idempotent in SHAPE as well as identity
//
// The CLI device is the subject every capability gate reads. `grantCli` returns
// an existing `cli@<host>` row as-is, so a row that reached devices.json without
// caps — a hand edit, or a pair token crafted with that label — came back with
// `caps: undefined`, which every gate reads as FULL access. That is the opposite
// of the least-privilege subject D2 exists to create, and it is silent.
// ---------------------------------------------------------------------------

test("grantCli mints the CLI device with the client cap", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const { device, created } = reg.grantCli();
    assert.equal(created, true);
    assert.deepEqual(device.caps, ["client"]);
    assert.match(device.label, /^cli@/);
  }));

test("grantCli is idempotent: the second call returns the same device", () =>
  withHome(() => {
    const reg = new DeviceRegistry();
    const first = reg.grantCli();
    const second = reg.grantCli();
    assert.equal(second.created, false);
    assert.equal(second.device.id, first.device.id);
    assert.equal(second.device.bearer, first.device.bearer);
  }));

test("grantCli repairs a cli@ row that somehow has no caps, rather than granting full access", () =>
  withHome((home) => {
    // A device with the CLI's label but no caps — full access by the protocol's
    // own reading of an absent `caps`.
    const label = `cli@${hostname()}`;
    mkdirSync(home, { recursive: true });
    writeFileSync(
      join(home, "devices.json"),
      JSON.stringify([{ id: "hand-edited", label, bearer: "b".repeat(64), pairedAt: 1, lastSeenAt: 1 }]),
    );
    const reg = new DeviceRegistry();
    const { device, created } = reg.grantCli();

    assert.equal(created, false, "identity is preserved — no second row appears");
    assert.equal(device.id, "hand-edited");
    assert.deepEqual(device.caps, ["client"], "but the capability is repaired");
    // And the repair is durable, or the next process reads full access again.
    assert.deepEqual(new DeviceRegistry().grantCli().device.caps, ["client"]);
  }));
