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
import { AddressInfo, connect } from "node:net";
import { createHash } from "node:crypto";

import { MediaStore } from "./store.js";
import { attachMediaRoute } from "./route.js";

const BEARER = "device-bearer-abc";
const bytes = Buffer.from("0123456789"); // 10 bytes — easy range math

/** The id the store would give these bytes — asserts "nothing was stored". */
const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");

/**
 * Hand-rolled POST over a raw socket, so a body can be sent that DISAGREES with
 * its `Content-Length` header — something `fetch` will not do. Resolves with the
 * response status line's code, or 0 if the server closed without replying.
 */
function rawPost(
  port: number,
  mime: string,
  declaredLength: number,
  body: Buffer,
  opts: { closeAfterBody?: boolean } = {},
): Promise<number> {
  return new Promise((resolve, reject) => {
    const sock = connect(port, "127.0.0.1", () => {
      sock.write(
        `POST /media HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer ${BEARER}\r\n` +
          `Content-Type: ${mime}\r\nContent-Length: ${declaredLength}\r\n\r\n`,
      );
      sock.write(body);
      // Simulates a client dying mid-upload: fewer bytes than declared, then FIN.
      if (opts.closeAfterBody) sock.end();
    });
    let seen = "";
    const statusOf = () => {
      const m = /^HTTP\/1\.\d (\d{3})/.exec(seen);
      return m ? Number(m[1]) : 0;
    };
    // NOT unref'd: this timer is the only thing guaranteeing the promise settles
    // when the server never replies (which is itself a failure worth reporting).
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error("rawPost timed out — server never responded"));
    }, 5000);
    const settle = (v: number) => {
      clearTimeout(timer);
      sock.destroy();
      resolve(v);
    };
    sock.on("data", (chunk) => {
      seen += chunk.toString("latin1");
      if (statusOf()) settle(statusOf());
    });
    sock.on("close", () => settle(statusOf()));
    sock.on("error", (err) => {
      clearTimeout(timer);
      // A 413 that closes the connection mid-body surfaces as ECONNRESET on the
      // write side; the status line we already read is the real outcome.
      if (statusOf()) resolve(statusOf());
      else reject(err);
    });
  });
}

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
  server.on("request", (req, res) => {
    // Only stand in for "some other handler" on paths the media route does not
    // own. It cannot be a blanket fallthrough: the upload handler answers
    // *asynchronously* (after the body arrives), so a second listener running
    // synchronously after it would win the race and 418 every POST. Production
    // listeners (`server.ts`) register no request handler at all, so this is a
    // test-harness concern only.
    if (req.url?.startsWith("/media")) return;
    if (res.headersSent || res.writableEnded) return;
    res.statusCode = 418; // proves the route did NOT handle this request
    res.end("fallthrough");
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;
  const url = (id = descriptor.mediaId) => `http://127.0.0.1:${port}/media/${id}`;
  const uploadUrl = () => `http://127.0.0.1:${port}/media`;
  const auth = { Authorization: `Bearer ${BEARER}` };
  // closeAllConnections: `fetch` keeps sockets alive, which would keep the
  // test process running long after `close()`.
  const close = () => {
    server.closeAllConnections();
    server.close();
  };
  return { store, descriptor, server, url, uploadUrl, auth, close };
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

// ---------- upload (SPEC-user-attachments) ----------------------------------------------
//
// The upload path is the *input* half of makit's media story: the phone POSTs a
// screenshot, gets a content-addressed id back, and names that id in
// `send.message`. Everything here is about refusing to allocate memory for a
// caller we have not authenticated or a payload we will not store.

const png = Buffer.from("89504e470d0a1a0a-not-a-real-png", "utf8");

/** POST helper — `fetch` needs an explicit length for a Buffer body. */
async function post(
  url: string,
  body: Buffer,
  opts: { mime?: string; auth?: boolean; length?: string } = {},
) {
  const headers: Record<string, string> = {};
  if (opts.mime !== undefined) headers["Content-Type"] = opts.mime;
  if (opts.auth !== false) headers.Authorization = `Bearer ${BEARER}`;
  if (opts.length !== undefined) headers["Content-Length"] = opts.length;
  return fetch(url, { method: "POST", headers, body: new Uint8Array(body) });
}

test("POST stores the bytes and returns the descriptor; GET round-trips them", async () => {
  const h = await harness();
  const res = await post(h.uploadUrl(), png, { mime: "image/png" });
  assert.equal(res.status, 201);
  assert.equal(res.headers.get("cache-control"), "no-store");
  const body = (await res.json()) as { mediaId: string; mime: string; sizeBytes: number };
  assert.match(body.mediaId, /^[a-f0-9]{64}$/);
  assert.equal(body.mime, "image/png");
  assert.equal(body.sizeBytes, png.length);

  const back = await fetch(h.url(body.mediaId), { headers: h.auth });
  assert.equal(back.status, 200);
  assert.deepEqual(Buffer.from(await back.arrayBuffer()), png);
  h.close();
});

test("POST is idempotent — the same bytes yield the same id", async () => {
  const h = await harness();
  const a = (await (await post(h.uploadUrl(), png, { mime: "image/png" })).json()) as {
    mediaId: string;
  };
  const b = (await (await post(h.uploadUrl(), png, { mime: "image/png" })).json()) as {
    mediaId: string;
  };
  assert.equal(a.mediaId, b.mediaId);
  h.close();
});

test("POST without a valid bearer is 401 and stores nothing", async () => {
  const h = await harness();
  const res = await post(h.uploadUrl(), png, { mime: "image/png", auth: false });
  assert.equal(res.status, 401);
  // Auth must be decided before the body is read, and nothing may be persisted.
  assert.equal(h.store.stat(sha256(png)), null);
  h.close();
});

test("POST with a non-allowlisted mime is 415 (no SVG, no HTML, no octet-stream)", async () => {
  const h = await harness();
  for (const mime of ["image/svg+xml", "text/html", "application/octet-stream", ""]) {
    const res = await post(h.uploadUrl(), png, { mime });
    assert.equal(res.status, 415, `mime=${JSON.stringify(mime)}`);
  }
  assert.equal(h.store.stat(sha256(png)), null);
  h.close();
});

test("POST larger than the store's cap is 413", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-media-upload-cap-"));
  const store = new MediaStore({ dir, maxBytes: 16 });
  const server = createServer();
  attachMediaRoute(server, {
    store,
    registry: { authenticate: (b: string) => (b === BEARER ? { id: "d", label: "p" } : null) },
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;
  const big = Buffer.alloc(17, 7);

  const res = await post(`http://127.0.0.1:${port}/media`, big, { mime: "image/png" });
  assert.equal(res.status, 413);
  assert.equal(store.stat(sha256(big)), null);

  server.closeAllConnections();
  server.close();
});

test("a body longer than its declared Content-Length cannot enlarge what we buffer", async () => {
  // Documenting a boundary rather than asserting a wish: Node's HTTP parser
  // stops the request body at `Content-Length`, so a sender that declares 8 and
  // writes 64 does NOT get 64 bytes buffered — the surplus is not part of this
  // request at all. That is precisely the attack this endpoint had to survive
  // (lie about the size, make the daemon allocate past its cap), and the
  // framework closes it before our code runs — so the assertion worth making is
  // "the 64 bytes are never stored", not a status code.
  const dir = mkdtempSync(join(tmpdir(), "makit-media-upload-liar-"));
  const store = new MediaStore({ dir, maxBytes: 1024 });
  const server = createServer();
  attachMediaRoute(server, {
    store,
    registry: { authenticate: () => ({ id: "d", label: "p" }) },
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;

  // Raw socket: `fetch` will not send a mismatched Content-Length for us.
  const payload = Buffer.alloc(64, 9);
  const status = await rawPost(port, "image/png", 8, payload);
  // Status is NOT asserted exactly: the 8-byte body can complete and answer 201
  // before the surplus fails to parse and answers 400, and `rawPost` resolves on
  // whichever status line it reads first. Asserting one of them would be a flaky
  // test for a property nobody depends on.
  assert.ok(status === 201 || status === 400, `unexpected status ${status}`);
  assert.equal(store.stat(sha256(payload)), null, "the full 64-byte body is never stored");
  // NOT asserted: whether the 8-byte prefix landed. That races the socket error
  // (body complete vs. parse failure) and is harmless either way — it is content
  // addressed, so a liar can only mis-reference its own upload. Asserting it
  // would buy a flaky test and no property worth having.

  server.closeAllConnections();
  server.close();
});

test("a chunked upload (no Content-Length) is 411, not an unbounded read", async () => {
  // Chunked transfer has no declared size, so there is no cap to admit it under.
  // Refusing is the only safe answer; the app always sends a length.
  const h = await harness();
  const res = await fetch(h.uploadUrl(), {
    method: "POST",
    headers: { Authorization: `Bearer ${BEARER}`, "Content-Type": "image/png" },
    body: new ReadableStream({
      start(c) {
        c.enqueue(new Uint8Array(png));
        c.close();
      },
    }),
    duplex: "half",
  } as RequestInit);
  assert.equal(res.status, 411);
  assert.equal(h.store.stat(sha256(png)), null);
  h.close();
});

test("a body shorter than its declared Content-Length stores nothing", async () => {
  // Client dies mid-upload. A truncated image must not be published under a hash
  // the client will then reference as though it were the whole file.
  const dir = mkdtempSync(join(tmpdir(), "makit-media-upload-short-"));
  const store = new MediaStore({ dir, maxBytes: 1024 });
  const server = createServer();
  attachMediaRoute(server, {
    store,
    registry: { authenticate: () => ({ id: "d", label: "p" }) },
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;

  const half = Buffer.alloc(8, 3);
  await rawPost(port, "image/png", 64, half, { closeAfterBody: true });
  assert.equal(store.stat(sha256(half)), null, "the partial body is not stored");

  server.closeAllConnections();
  server.close();
});

test("POST to a path below /media is not an upload", async () => {
  const h = await harness();
  const res = await post(`${h.uploadUrl()}/nested`, png, { mime: "image/png" });
  assert.notEqual(res.status, 201);
  h.close();
});

test("a store failure is a 500, not an uncaught exception that kills the daemon", async () => {
  // `store.put` does synchronous fs work inside an `end` event callback, where
  // the route's outer try/catch cannot reach it. A full disk must answer the
  // client, not crash the process.
  const dir = mkdtempSync(join(tmpdir(), "makit-media-upload-fail-"));
  const store = new MediaStore({ dir });
  store.put = () => {
    throw new Error("ENOSPC: no space left on device");
  };
  const server = createServer();
  attachMediaRoute(server, {
    store,
    registry: { authenticate: () => ({ id: "d", label: "p" }) },
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as AddressInfo).port;

  const uncaught: Error[] = [];
  const onUncaught = (err: Error) => uncaught.push(err);
  process.once("uncaughtException", onUncaught);

  const res = await post(`http://127.0.0.1:${port}/media`, png, { mime: "image/png" });
  assert.equal(res.status, 500);
  assert.deepEqual(JSON.parse(await res.text()), { error: "upload_failed" });
  await new Promise((r) => setTimeout(r, 20)); // let any stray throw surface
  assert.deepEqual(uncaught, [], "the failure must be handled, not thrown");

  process.removeListener("uncaughtException", onUncaught);
  server.closeAllConnections();
  server.close();
});
