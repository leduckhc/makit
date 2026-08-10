import assert from "node:assert/strict";
import { test } from "node:test";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

import { DocListener } from "./listener.js";

/**
 * SPEC-46 D10 rev 2: the doc listener is bound **lazily on first publish** and
 * closed once nothing is published, so makit does not hold a routable port open
 * for a feature you are not using. Tailnet only (rev 2 drops the LAN fallback),
 * so the capability in the URL never crosses a network WireGuard is not
 * encrypting.
 */

function listener(bindHost: string | null): { l: DocListener; opened: Server[] } {
  const opened: Server[] = [];
  const l = new DocListener({
    bindHost,
    createServer: () => {
      const s = createServer();
      opened.push(s);
      return s;
    },
    attach: () => {},
  });
  return { l, opened };
}

test("does not bind at all when the host is not a tailnet address", async () => {
  const { l, opened } = listener(null);
  assert.equal(await l.ensureOrigin(), null);
  assert.equal(opened.length, 0, "publish must not open a port it cannot use");
  assert.equal(l.isListening, false);
});

test("binds lazily on the first publish and reports a tailnet origin", async () => {
  const { l, opened } = listener("127.0.0.1");
  assert.equal(l.isListening, false, "nothing is bound before the first publish");

  const reach = await l.ensureOrigin();
  assert.ok(reach, "expected an origin");
  assert.equal(reach.reach, "tailnet");
  assert.match(reach.origin, /^http:\/\/127\.0\.0\.1:\d+$/);
  assert.equal(l.isListening, true);
  assert.equal(opened.length, 1);

  await l.close();
});

test("reuses the same listener across publishes", async () => {
  const { l, opened } = listener("127.0.0.1");
  const a = await l.ensureOrigin();
  const b = await l.ensureOrigin();
  assert.deepEqual(a, b, "a second publish must not open a second port");
  assert.equal(opened.length, 1);
  await l.close();
});

test("releaseIfIdle(0) closes the port; releaseIfIdle(n>0) keeps it", async () => {
  const { l } = listener("127.0.0.1");
  const reach = await l.ensureOrigin();
  assert.ok(reach);
  const port = Number(reach.origin.split(":").pop());

  await l.releaseIfIdle(2);
  assert.equal(l.isListening, true, "grants outstanding — the port must stay open");

  await l.releaseIfIdle(0);
  assert.equal(l.isListening, false, "nothing published — the port must be released");

  // And the port really is free again: a fresh listener can take it.
  const probe = createServer();
  await new Promise<void>((r, rej) => {
    probe.once("error", rej);
    probe.listen(port, "127.0.0.1", () => r());
  });
  probe.close();
});

test("re-binds after a release, so publishing again still works", async () => {
  const { l, opened } = listener("127.0.0.1");
  await l.ensureOrigin();
  await l.releaseIfIdle(0);

  const again = await l.ensureOrigin();
  assert.ok(again, "a later publish must be able to bind again");
  assert.equal(l.isListening, true);
  assert.equal(opened.length, 2, "a new server object per bind");
  await l.close();
});

test("a bind failure degrades loudly: null, not a dead URL (D15)", async () => {
  // Occupy a port, then force the listener at it so listen() fails.
  const blocker = createServer();
  await new Promise<void>((r) => blocker.listen(0, "127.0.0.1", () => r()));
  const taken = (blocker.address() as AddressInfo).port;

  const l = new DocListener({
    bindHost: "127.0.0.1",
    createServer,
    attach: () => {},
    port: taken,
  });
  assert.equal(await l.ensureOrigin(), null, "a failed bind must not yield a URL");
  assert.equal(l.isListening, false);
  blocker.close();
});

test("close() is idempotent and safe before any bind", async () => {
  const { l } = listener("127.0.0.1");
  await l.close();
  await l.close();
  assert.equal(l.isListening, false);
});

// Two clients publishing at once both passed the `origin === undefined` check and
// bound their own port; the first listener was then unreachable and unclosable.
test("concurrent ensureOrigin calls share one bind, not one each", async () => {
  const { l, opened } = listener("127.0.0.1");

  const [a, b, c] = await Promise.all([
    l.ensureOrigin(),
    l.ensureOrigin(),
    l.ensureOrigin(),
  ]);
  assert.equal(opened.length, 1, "one listener for three concurrent publishes");
  assert.deepEqual(a, b);
  assert.deepEqual(b, c);
  assert.notEqual(a, null);
  await l.close();
  assert.equal(l.isListening, false);
});
