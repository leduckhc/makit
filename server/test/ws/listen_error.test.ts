/**
 * Listen failures (e.g. a stale dev server already squatting on the port)
 * must surface through `onListenError` — a clear, actionable diagnostic —
 * instead of node's default unhandled-'error' crash. This was a real
 * production failure mode: a leftover `tsx watch` held 8787, the daemon died
 * with a bare EADDRINUSE stack, and the app showed nothing.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";

import { SessionManager } from "../../src/manager.js";
import { startWsServer } from "../../src/server.js";
import { loadOrCreateCert } from "../../src/pairing/cert.js";
import { DeviceRegistry } from "../../src/pairing/registry.js";

test("a port collision invokes onListenError with EADDRINUSE instead of crashing", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-listen-home-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;
  const cert = await loadOrCreateCert();

  const first = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager: new SessionManager({ projects: [] }),
    cert,
    registry: new DeviceRegistry(),
  });
  await new Promise<void>((r) => (first.https.listening ? r() : first.https.once("listening", () => r())));
  const port = (first.https.address() as AddressInfo).port;

  const errors: Array<{ code?: string; where: string }> = [];
  const second = startWsServer({
    host: "127.0.0.1",
    port,
    manager: new SessionManager({ projects: [] }),
    cert,
    registry: new DeviceRegistry(),
    onListenError: (err, where) => errors.push({ code: err.code, where }),
  });

  try {
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(errors.length, 1);
    assert.equal(errors[0].code, "EADDRINUSE");
    assert.equal(errors[0].where, `127.0.0.1:${port}`);
  } finally {
    first.wss.close();
    first.https.close();
    first.localHttps?.close();
    second.wss.close();
    second.https.close();
    second.localHttps?.close();
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
  }
});
