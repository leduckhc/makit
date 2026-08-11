/**
 * Doc route tests — drives the handler through a real `http.Server` so status
 * codes, `Content-Type` and `HEAD` are exercised end-to-end, exactly as the
 * media route test does. The doc listener carries NO bearer: the capability is
 * the unguessable `grantId` in the path (D9).
 */

import assert from "node:assert/strict";
import { test } from "node:test";
import { createServer } from "node:http";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";

import { DocGrantStore } from "./grants.js";
import { attachDocRoute, attachDocNotFound } from "./route.js";

async function harness() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "makit-docroute-")));
  mkdirSync(join(root, "mockups"), { recursive: true });
  writeFileSync(join(root, "mockups", "board.html"), "<title>Board</title><h1>hi</h1>");
  writeFileSync(join(root, "spec.md"), "# Spec\n");
  writeFileSync(join(root, ".env"), "SECRET=1\n");

  const grants = new DocGrantStore();
  const html = grants.mint({
    worktreePath: root,
    relPath: "mockups/board.html",
    reach: "lan",
    buildUrl: (id) => `http://x/docs/${id}/mockups/board.html`,
  });
  const md = grants.mint({
    worktreePath: root,
    relPath: "spec.md",
    reach: "lan",
    buildUrl: (id) => `http://x/docs/${id}/spec.md`,
  });

  const server = createServer();
  attachDocRoute(server, { grants });
  // A fallthrough handler scoped to paths the route does NOT own — a blanket
  // second handler would win the race against the route's async reply and mask
  // real 404s (our test-history trap).
  server.on("request", (req, res) => {
    if (!(req.url ?? "").startsWith("/docs/")) {
      res.writeHead(418);
      res.end("teapot");
    }
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;
  return { server, port, grants, html, md, root };
}

async function req(port: number, path: string, method = "GET") {
  const res = await fetch(`http://127.0.0.1:${port}${path}`, { method });
  return { status: res.status, ctype: res.headers.get("content-type"), body: await res.text() };
}

test("serves a published html file with the right Content-Type", async () => {
  const h = await harness();
  try {
    const r = await req(h.port, `/docs/${h.html.grantId}/mockups/board.html`);
    assert.equal(r.status, 200);
    assert.match(r.ctype ?? "", /text\/html/);
    assert.match(r.body, /<h1>hi<\/h1>/);
  } finally {
    h.server.close();
  }
});

test("serves markdown with a text/markdown Content-Type", async () => {
  const h = await harness();
  try {
    const r = await req(h.port, `/docs/${h.md.grantId}/spec.md`);
    assert.equal(r.status, 200);
    assert.match(r.ctype ?? "", /text\/markdown/);
  } finally {
    h.server.close();
  }
});

test("HEAD is supported and returns headers with no body", async () => {
  const h = await harness();
  try {
    const r = await req(h.port, `/docs/${h.html.grantId}/mockups/board.html`, "HEAD");
    assert.equal(r.status, 200);
    assert.match(r.ctype ?? "", /text\/html/);
    assert.equal(r.body, "");
  } finally {
    h.server.close();
  }
});

test("an unknown grantId is 404, never 403 (does not confirm existence)", async () => {
  const h = await harness();
  try {
    const r = await req(h.port, `/docs/${"0".repeat(64)}/mockups/board.html`);
    assert.equal(r.status, 404);
  } finally {
    h.server.close();
  }
});

test("an expired/revoked grant is 404", async () => {
  const h = await harness();
  try {
    h.grants.revoke(h.html.grantId);
    const r = await req(h.port, `/docs/${h.html.grantId}/mockups/board.html`);
    assert.equal(r.status, 404);
  } finally {
    h.server.close();
  }
});

test("a traversal attempt is 404, not a served secret", async () => {
  const h = await harness();
  try {
    const r = await req(h.port, `/docs/${h.html.grantId}/..%2f..%2f.env`);
    assert.equal(r.status, 404);
    assert.ok(!r.body.includes("SECRET"), "a secret leaked through traversal");
  } finally {
    h.server.close();
  }
});

test("a valid grant but a different relPath is 404 (the grant is scoped to one doc)", async () => {
  const h = await harness();
  try {
    const r = await req(h.port, `/docs/${h.html.grantId}/spec.md`);
    assert.equal(r.status, 404);
  } finally {
    h.server.close();
  }
});

test("a path the route does not own is left to the other handler", async () => {
  const h = await harness();
  try {
    const r = await req(h.port, `/elsewhere`);
    assert.equal(r.status, 418);
  } finally {
    h.server.close();
  }
});

// ── the dedicated listener must always answer ──────────────────────────────
// `attachDocRoute` deliberately ignores non-/docs paths so it can share a
// listener (and so a test harness fallthrough can own other paths). But the doc
// listener in server.ts is DEDICATED: nothing else is attached, so an unmatched
// request gets no response at all and the socket hangs until Node's 60 s headers
// timeout. A live probe found this: `/`, `/favicon.ico` and `/etc/passwd` all
// hung. Safari requests /favicon.ico on every visit, and the listener is bound
// to a routable address, so this is a free socket-exhaustion vector.
test("attachDocNotFound terminates every request the doc route did not answer", async () => {
  const server = createServer();
  attachDocRoute(server, { grants: new DocGrantStore() });
  attachDocNotFound(server);
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;
  try {
    for (const path of ["/", "/favicon.ico", "/etc/passwd", "/docs", "/docsx", "/../etc/passwd"]) {
      const res = await fetch(`http://127.0.0.1:${port}${path}`);
      assert.equal(res.status, 404, `${path} must be answered, not left hanging`);
      await res.text();
    }
    // The real route still wins for its own prefix.
    const own = await fetch(`http://127.0.0.1:${port}/docs/${"0".repeat(64)}/a.md`);
    assert.equal(own.status, 404);
    await own.text();
  } finally {
    server.close();
  }
});
