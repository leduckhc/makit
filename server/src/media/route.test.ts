/**
 * Media route tests — drives the handler through a real `http.Server` so
 * status codes, `Range` handling and headers are exercised end-to-end.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AddressInfo } from "node:net";

import { MediaStore } from "./store.js";
import { attachMediaRoute } from "./route.js";

const BEARER = "device-bearer-abc";
const bytes = Buffer.from("0123456789"); // 10 bytes — easy range math

async function harness() {
  const dir = mkdtempSync(join(tmpdir(), "makit-media-route-"));
  const store = new MediaStore({ dir });
  const descriptor = store.put(bytes, "image/png");
  // Production listeners (`server.ts`) are created with NO request handler, so
  // the media route is the only responder. This fallthrough stands in for "some
  // other handler" and proves the route ignores non-/media paths; it must not
  // double-respond, hence the headersSent guard.
  const server: Server = createServer();
  attachMediaRoute(server, {
    store,
    registry: {
      authenticate: (b: string) => (b === BEARER ? { id: "dev-1", label: "phone" } : null),
    },
  });
  server.on("request", (_req, res) => {
    if (res.headersSent || res.writableEnded) return;
    res.statusCode = 418; // proves the route did NOT handle this request
    res.end("fallthrough");
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;
  const url = (id = descriptor.mediaId) => `http://127.0.0.1:${port}/media/${id}`;
  const auth = { Authorization: `Bearer ${BEARER}` };
  // closeAllConnections: `fetch` keeps sockets alive, which would keep the
  // test process running long after `close()`.
  const close = () => {
    server.closeAllConnections();
    server.close();
  };
  return { store, descriptor, server, url, auth, close };
}

test("GET with a valid bearer serves the bytes with mime, length and Accept-Ranges", async () => {
  const h = await harness();
  const res = await fetch(h.url(), { headers: h.auth });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "image/png");
  assert.equal(res.headers.get("content-length"), "10");
  assert.equal(res.headers.get("accept-ranges"), "bytes");
  // Content-addressed ⇒ immutable ⇒ cacheable forever.
  assert.match(res.headers.get("cache-control") ?? "", /immutable/);
  assert.equal(Buffer.from(await res.arrayBuffer()).toString(), "0123456789");
  h.close();
});

test("HEAD returns the headers with no body", async () => {
  const h = await harness();
  const res = await fetch(h.url(), { method: "HEAD", headers: h.auth });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-length"), "10");
  assert.equal((await res.text()).length, 0);
  h.close();
});

test("a missing or wrong bearer is 401 and never touches the store", async () => {
  const h = await harness();
  assert.equal((await fetch(h.url())).status, 401);
  assert.equal((await fetch(h.url(), { headers: { Authorization: "Bearer nope" } })).status, 401);
  assert.equal((await fetch(h.url(), { headers: { Authorization: BEARER } })).status, 401, "scheme required");
  h.close();
});

test("a GC'd or malformed id is 404 JSON — never a 500 and never a fallback image", async () => {
  const h = await harness();
  // NB `../store.ts` never reaches the route — fetch/RFC-3986 normalizes it out
  // of the path client-side. Percent-encoded traversal DOES arrive, so that is
  // the case worth asserting.
  for (const id of ["f".repeat(64), "not-a-hash", "%2e%2e%2fstore.ts", ""]) {
    const res = await fetch(h.url(id), { headers: h.auth });
    assert.equal(res.status, 404, `id ${JSON.stringify(id)}`);
    assert.equal(res.headers.get("content-type"), "application/json");
    assert.deepEqual(await res.json(), { error: "media_not_found" });
  }
  h.close();
});

test("Range yields 206 with Content-Range and only the requested bytes", async () => {
  const h = await harness();
  const cases: Array<[string, number, string, string]> = [
    ["bytes=0-3", 206, "bytes 0-3/10", "0123"],
    ["bytes=4-", 206, "bytes 4-9/10", "456789"],
    ["bytes=-3", 206, "bytes 7-9/10", "789"],
    ["bytes=5-99", 206, "bytes 5-9/10", "56789"], // clamped to the end
  ];
  for (const [range, status, contentRange, body] of cases) {
    const res = await fetch(h.url(), { headers: { ...h.auth, Range: range } });
    assert.equal(res.status, status, range);
    assert.equal(res.headers.get("content-range"), contentRange, range);
    assert.equal(await res.text(), body, range);
  }
  h.close();
});

test("an unsatisfiable range is 416 with the resource size", async () => {
  const h = await harness();
  const res = await fetch(h.url(), { headers: { ...h.auth, Range: "bytes=50-60" } });
  assert.equal(res.status, 416);
  assert.equal(res.headers.get("content-range"), "bytes */10");
  h.close();
});

test("a malformed/multi Range header falls back to the full 200 body", async () => {
  const h = await harness();
  for (const range of ["bytes=abc", "items=0-1", "bytes=0-1,4-5"]) {
    const res = await fetch(h.url(), { headers: { ...h.auth, Range: range } });
    assert.equal(res.status, 200, range);
    assert.equal(await res.text(), "0123456789", range);
  }
  h.close();
});

test("a non-GET/HEAD method is 405", async () => {
  const h = await harness();
  const res = await fetch(h.url(), { method: "DELETE", headers: h.auth });
  assert.equal(res.status, 405);
  h.close();
});

test("non-/media paths are left to the rest of the server", async () => {
  const h = await harness();
  const res = await fetch(h.url().replace("/media/", "/other/"), { headers: h.auth });
  assert.equal(res.status, 418, "the pre-existing request handler still runs");
  h.close();
});

test("trustLoopback serves a bearer-less loopback client (dev --no-auth parity)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-media-route-dev-"));
  const store = new MediaStore({ dir });
  const d = store.put(bytes, "image/png");
  const server = createServer();
  attachMediaRoute(server, {
    store,
    registry: { authenticate: () => null }, // no device is ever valid
    trustLoopback: true,
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;

  const res = await fetch(`http://127.0.0.1:${port}/media/${d.mediaId}`);
  assert.equal(res.status, 200, "loopback is trusted when the WS is");
  assert.equal(await res.text(), "0123456789");

  server.closeAllConnections();
  server.close();
});
