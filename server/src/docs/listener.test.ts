import assert from "node:assert/strict";
import { test } from "node:test";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

import { DocListener } from "./listener.js";

/**
 * SPEC-doc-preview D10 rev 2: the doc listener is bound **lazily on first publish** and
 * closed once nothing is published, so makit does not hold a routable port open
 * for a feature you are not using. Tailnet only (rev 2 drops the LAN fallback),
 * so the capability in the URL never crosses a network WireGuard is not
 * encrypting.
 */

function listener(bindHost: string | null): {
  l: DocListener;
  opened: Server[];
  live: { grants: number };
} {
  const opened: Server[] = [];
  // The listener reads this at the moment it decides to release, the way
  // `server.ts` hands it `docGrants.list().length`.
  const live = { grants: 0 };
  const l = new DocListener({
    bindHost,
    liveGrants: () => live.grants,
    createServer: () => {
      const s = createServer();
      opened.push(s);
      return s;
    },
    attach: () => {},
  });
  return { l, opened, live };
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

test("releaseIfIdle closes the port only when no grant is live", async () => {
  const { l, live } = listener("127.0.0.1");
  const reach = await l.ensureOrigin();
  assert.ok(reach);
  const port = Number(reach.origin.split(":").pop());

  live.grants = 2;
  await l.releaseIfIdle();
  assert.equal(l.isListening, true, "grants outstanding — the port must stay open");

  live.grants = 0;
  await l.releaseIfIdle();
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
  await l.releaseIfIdle();

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
    liveGrants: () => 0,
    createServer,
    attach: () => {},
    port: taken,
  });
  assert.equal(await l.ensureOrigin(), null, "a failed bind must not yield a URL");
  assert.equal(l.isListening, false);
  blocker.close();
});

// A publish reads the origin and THEN mints the grant that names it. Until that
// grant exists the count is zero, so a release arriving from another command
// (docs.grants, docs.unpublish) closed the port under the publish and the user
// got a URL for a dead socket. A lease must outrank the count.
test("a release during a lease is deferred, then honoured when the lease ends", async () => {
  const { l, live } = listener("127.0.0.1");

  const reached = await l.withOrigin(async (reach) => {
    assert.ok(reach, "the lease must carry a bound origin");
    // Zero grants, exactly as in the window before the grant is minted.
    live.grants = 0;
    await l.releaseIfIdle();
    assert.equal(l.isListening, true, "a release must not close the port under a publish");
    // The grant now exists, which is what keeps the port open after the lease.
    live.grants = 1;
    return reach.origin;
  });
  assert.match(reached, /^http:\/\/127\.0\.0\.1:\d+$/);
  assert.equal(l.isListening, true, "a live grant keeps the port bound");

  live.grants = 0;
  await l.releaseIfIdle();
  assert.equal(l.isListening, false, "the deferred release is not a permanent reprieve");
});

// Concurrent publishes must not let the FIRST one's exit close the port under the
// second: the lease count, not a boolean, decides.
test("overlapping leases keep the port until the last one ends", async () => {
  const { l, live } = listener("127.0.0.1");
  let releaseFirst: (() => void) | undefined;
  const first = l.withOrigin(async () => {
    await new Promise<void>((r) => (releaseFirst = r));
  });
  const second = l.withOrigin(async () => {
    releaseFirst?.();
    await first; // the first lease is fully gone before this one checks
    await l.releaseIfIdle();
    assert.equal(l.isListening, true, "a second publish still holds the port");
  });
  await Promise.all([first, second]);

  live.grants = 0;
  await l.releaseIfIdle();
  assert.equal(l.isListening, false);
});

test("a lease over an unbindable host hands the callback null, not a dead origin", async () => {
  const { l, opened } = listener(null);
  const seen = await l.withOrigin(async (reach) => reach);
  assert.equal(seen, null, "publish must refuse rather than mint a URL");
  assert.equal(opened.length, 0);
});

test("a lease that ends with nothing published releases the port it took", async () => {
  const { l } = listener("127.0.0.1");
  await l.withOrigin(async (reach) => {
    assert.ok(reach);
    // No grant is minted — a refusal after the bind, or a mint that threw.
  });
  // The lease end must re-check, or the port stays bound with nothing published
  // until the next unrelated grant-list read.
  const deadline = Date.now() + 2_000;
  while (l.isListening && Date.now() < deadline) await new Promise((r) => setTimeout(r, 10));
  assert.equal(l.isListening, false, "an idle port must not survive its lease");
});

// A phone that fetched a doc leaves its socket in the keep-alive pool. The
// release must not wait that socket out: a publish arriving mid-close awaits the
// close, so a stalled release becomes a stalled share. (Node's `close()` drops
// pooled sockets for us; this test keeps that guarantee from regressing.)
test("a release does not wait out a pooled keep-alive socket", async () => {
  const opened: Server[] = [];
  const l = new DocListener({
    bindHost: "127.0.0.1",
    liveGrants: () => 0,
    createServer: () => {
      const s = createServer();
      opened.push(s);
      return s;
    },
    attach: (s) =>
      s.on("request", (_req, res) => {
        res.writeHead(200, { "content-type": "text/plain" });
        res.end("doc");
      }),
  });

  const reach = await l.ensureOrigin();
  assert.ok(reach);
  // A real fetch, which leaves the connection pooled exactly as a phone does.
  const res = await fetch(`${reach.origin}/docs/x/spec.md`);
  assert.equal(res.status, 200);
  await res.text();
  // Let the socket settle into the keep-alive pool. Node classifies a connection
  // as idle a tick after the last byte, and the case under test is a release
  // that arrives LATER (an unpublish, or a TTL expiry), not one racing the byte.
  await new Promise((r) => setTimeout(r, 50));

  const started = Date.now();
  await l.releaseIfIdle();
  const took = Date.now() - started;

  assert.equal(l.isListening, false, "the port must actually be released");
  assert.ok(took < 1_000, `the release must not wait out the keep-alive: took ${took}ms`);
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

// close() clears server/origin before the socket is fully down. A publish that
// lands mid-close must wait it out, not bind a second port beside the closing one.
test("close() during an in-flight bind leaves no listener behind", async () => {
  const { l, opened } = listener("127.0.0.1");
  const pending = l.ensureOrigin();
  await l.close();
  await pending;
  assert.equal(l.isListening, false, "the bind that landed mid-close must be released");
  assert.equal(opened.length, 1, "exactly one server object, not one per call");
  assert.equal(opened[0]!.listening, false, "the socket must not stay bound");
});

test("a publish arriving mid-close binds a fresh listener, not a second live one", async () => {
  const { l, opened } = listener("127.0.0.1");
  await l.ensureOrigin();
  const closing = l.close();
  const reopened = l.ensureOrigin(); // arrives before close resolves
  await Promise.all([closing, reopened]);
  assert.equal(l.isListening, true, "the later publish must be able to bind again");
  assert.equal(opened.length, 2, "one closed, one fresh — never two live at once");
  assert.equal(opened[0]!.listening, false, "the first socket is fully down");
  await l.close();
});
