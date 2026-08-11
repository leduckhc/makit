/**
 * SPEC-44 P4b — the forward proxy, driven against a REAL loopback
 * `http.Server` standing in for the dev server (the `media/route.test.ts`
 * pattern). Nothing here is mocked at the socket level, so the tests exercise
 * genuine streaming, real header handling and real connection failures.
 */

import assert from "node:assert/strict";
import { test } from "node:test";
import { createServer, request as httpRequest, type Server } from "node:http";
import type { AddressInfo } from "node:net";

import { ForwardGrants } from "./forward_grants.js";
import {
  attachForwardRoute,
  rewriteResponseHeaders,
  splitPath,
} from "./forward_route.js";

const DEVICE = { id: "dev-1", label: "phone" };
const BEARER = "tok-abc";

/** A registry that knows exactly one bearer. */
const registry = {
  authenticate: (bearer: string) => (bearer === BEARER ? DEVICE : null),
};

interface Harness {
  /** Base URL of the makit-side proxy listener. */
  base: string;
  grants: ForwardGrants;
  /** Port the fake dev server listens on. */
  devPort: number;
  /** Requests the fake dev server received. */
  seen: { method: string; url: string; body: string; headers: Record<string, unknown> }[];
  stop: () => Promise<void>;
}

async function listen(server: Server): Promise<number> {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return (server.address() as AddressInfo).port;
}

async function harness(
  devHandler?: (req: import("node:http").IncomingMessage, res: import("node:http").ServerResponse) => void,
  opts: { trustLoopback?: boolean } = {},
): Promise<Harness> {
  const seen: Harness["seen"] = [];
  const dev = createServer((req, res) => {
    let body = "";
    req.on("data", (c: Buffer) => (body += c.toString()));
    req.on("end", () => {
      seen.push({
        method: req.method ?? "",
        url: req.url ?? "",
        body,
        headers: req.headers as Record<string, unknown>,
      });
      if (devHandler) {
        devHandler(req, res);
        return;
      }
      res.writeHead(200, { "content-type": "text/plain" });
      res.end(`dev says ${req.method} ${req.url}`);
    });
  });
  const devPort = await listen(dev);

  const grants = new ForwardGrants({ now: () => Date.now() });
  const proxy = createServer();
  attachForwardRoute(proxy, {
    grants,
    registry,
    trustLoopback: opts.trustLoopback,
    loopbackDeviceId: opts.trustLoopback === true ? DEVICE.id : undefined,
  });
  // A default 404 for anything the route does not claim, so a mis-pathed test
  // fails fast instead of hanging.
  proxy.on("request", (req, res) => {
    if (!req.url?.startsWith("/forward/")) {
      res.writeHead(404);
      res.end();
    }
  });
  const proxyPort = await listen(proxy);

  return {
    base: `http://127.0.0.1:${proxyPort}`,
    grants,
    devPort,
    seen,
    stop: async () => {
      await new Promise<void>((r) => dev.close(() => r()));
      await new Promise<void>((r) => proxy.close(() => r()));
    },
  };
}

function authed(extra: Record<string, string> = {}): Record<string, string> {
  return { authorization: `Bearer ${BEARER}`, ...extra };
}

// ── path parsing ───────────────────────────────────────────────────────────

test("splitPath separates the grant from the upstream path", () => {
  assert.deepEqual(splitPath("/forward/abc/index.html"), {
    grantId: "abc",
    rest: "/index.html",
  });
  assert.deepEqual(splitPath("/forward/abc/x?y=1"), { grantId: "abc", rest: "/x?y=1" });
  assert.deepEqual(splitPath("/forward/abc"), { grantId: "abc", rest: "/" });
  assert.deepEqual(splitPath("/forward/abc?q=1"), { grantId: "abc", rest: "/?q=1" });
  assert.equal(splitPath("/forward/"), null);
  assert.equal(splitPath("/media/abc"), null);
});

// ── auth + grants ──────────────────────────────────────────────────────────

test("a request with NO bearer is 401", async () => {
  const h = await harness();
  try {
    const g = h.grants.mint({ deviceId: DEVICE.id, port: h.devPort, worktreePath: "/wt" });
    const res = await fetch(`${h.base}/forward/${g.grantId}/`);
    assert.equal(res.status, 401);
    assert.equal(h.seen.length, 0, "the dev server must never be touched");
  } finally {
    await h.stop();
  }
});

test("an authenticated request with an UNKNOWN grant is 403, not 404", async () => {
  // The caller *is* authenticated; it is the grant that is gone. A 404 would
  // read as "no such page" and send the WebView down the wrong path.
  const h = await harness();
  try {
    const res = await fetch(`${h.base}/forward/nope/`, { headers: authed() });
    assert.equal(res.status, 403);
    assert.equal(h.seen.length, 0);
  } finally {
    await h.stop();
  }
});

test("another device's grant is 403", async () => {
  const h = await harness();
  try {
    const g = h.grants.mint({ deviceId: "dev-2", port: h.devPort, worktreePath: "/wt" });
    const res = await fetch(`${h.base}/forward/${g.grantId}/`, { headers: authed() });
    assert.equal(res.status, 403);
  } finally {
    await h.stop();
  }
});

test("a revoked grant stops working immediately", async () => {
  const h = await harness();
  try {
    const g = h.grants.mint({ deviceId: DEVICE.id, port: h.devPort, worktreePath: "/wt" });
    assert.equal((await fetch(`${h.base}/forward/${g.grantId}/`, { headers: authed() })).status, 200);
    h.grants.stop(g.grantId, DEVICE.id);
    assert.equal((await fetch(`${h.base}/forward/${g.grantId}/`, { headers: authed() })).status, 403);
  } finally {
    await h.stop();
  }
});

test("a loopback caller under trustLoopback needs no bearer (dev mode)", async () => {
  const h = await harness(undefined, { trustLoopback: true });
  try {
    const g = h.grants.mint({ deviceId: DEVICE.id, port: h.devPort, worktreePath: "/wt" });
    const res = await fetch(`${h.base}/forward/${g.grantId}/`);
    assert.equal(res.status, 200);
  } finally {
    await h.stop();
  }
});

// ── proxying ───────────────────────────────────────────────────────────────

test("a GET is proxied byte-for-byte, path and query intact", async () => {
  const h = await harness();
  try {
    const g = h.grants.mint({ deviceId: DEVICE.id, port: h.devPort, worktreePath: "/wt" });
    const res = await fetch(`${h.base}/forward/${g.grantId}/app.js?v=2`, { headers: authed() });
    assert.equal(res.status, 200);
    assert.equal(await res.text(), "dev says GET /app.js?v=2");
    assert.equal(h.seen[0]?.url, "/app.js?v=2");
  } finally {
    await h.stop();
  }
});

test("POST/PUT/DELETE and their bodies pass through", async () => {
  const h = await harness();
  try {
    const g = h.grants.mint({ deviceId: DEVICE.id, port: h.devPort, worktreePath: "/wt" });
    for (const method of ["POST", "PUT", "DELETE", "PATCH"]) {
      const res = await fetch(`${h.base}/forward/${g.grantId}/api`, {
        method,
        headers: authed({ "content-type": "application/json" }),
        body: method === "DELETE" ? undefined : '{"a":1}',
      });
      assert.equal(res.status, 200, method);
    }
    assert.deepEqual(
      h.seen.map((s) => s.method),
      ["POST", "PUT", "DELETE", "PATCH"],
    );
    assert.equal(h.seen[0]?.body, '{"a":1}');
  } finally {
    await h.stop();
  }
});

test("the makit bearer is NEVER forwarded to the dev server", async () => {
  const h = await harness();
  try {
    const g = h.grants.mint({ deviceId: DEVICE.id, port: h.devPort, worktreePath: "/wt" });
    await fetch(`${h.base}/forward/${g.grantId}/`, { headers: authed() });
    assert.equal(
      h.seen[0]?.headers.authorization,
      undefined,
      "a dev server must not learn the pairing credential",
    );
  } finally {
    await h.stop();
  }
});

test("a streamed response streams — it is not buffered whole", async () => {
  let release: (() => void) | undefined;
  const h = await harness((_, res) => {
    res.writeHead(200, { "content-type": "text/event-stream" });
    res.write("data: one\n\n");
    release = () => {
      res.write("data: two\n\n");
      res.end();
    };
  });
  try {
    const g = h.grants.mint({ deviceId: DEVICE.id, port: h.devPort, worktreePath: "/wt" });
    const res = await fetch(`${h.base}/forward/${g.grantId}/events`, { headers: authed() });
    const reader = res.body!.getReader();
    const first = await reader.read();
    // The first chunk arrives while the upstream response is still OPEN, which
    // is the property a buffering proxy would break.
    assert.match(new TextDecoder().decode(first.value), /data: one/);
    release?.();
    const second = await reader.read();
    assert.match(new TextDecoder().decode(second.value ?? new Uint8Array()), /data: two/);
  } finally {
    await h.stop();
  }
});

test("a dead upstream is 502 (distinct from a missing grant's 403)", async () => {
  const h = await harness();
  try {
    // A grant for a port nothing listens on: 502 says "your dev server is gone",
    // which is a different fix from "your forward expired".
    const g = h.grants.mint({ deviceId: DEVICE.id, port: 9, worktreePath: "/wt" });
    const res = await fetch(`${h.base}/forward/${g.grantId}/`, { headers: authed() });
    assert.equal(res.status, 502);
  } finally {
    await h.stop();
  }
});

test("an Upgrade request is refused with 426, never half-proxied (D5)", async () => {
  // Vite computes its HMR socket URL from `location`, so behind a proxy it dials
  // the wrong ws:// and silently degrades. A loud refusal is the honest failure.
  const h = await harness();
  try {
    const g = h.grants.mint({ deviceId: DEVICE.id, port: h.devPort, worktreePath: "/wt" });
    // `fetch` forbids setting `Upgrade`, so this one speaks raw HTTP.
    const status = await new Promise<number>((resolve, reject) => {
      const req = httpRequest(
        {
          host: "127.0.0.1",
          port: Number(new URL(h.base).port),
          path: `/forward/${g.grantId}/`,
          headers: { ...authed(), upgrade: "websocket", connection: "Upgrade" },
        },
        (res) => {
          res.resume();
          resolve(res.statusCode ?? 0);
        },
      );
      req.on("error", reject);
      req.end();
    });
    assert.equal(status, 426);
    assert.equal(h.seen.length, 0);
  } finally {
    await h.stop();
  }
});

// ── header rewriting (pure) ────────────────────────────────────────────────

test("a Location on the target loopback origin is rewritten onto the proxy path", () => {
  const out = rewriteResponseHeaders(
    { location: "http://127.0.0.1:5173/login?next=/x" },
    5173,
    "GID",
  );
  assert.equal(out.location, "/forward/GID/login?next=/x");
});

test("a Location with no path still lands on the upstream root", () => {
  const out = rewriteResponseHeaders({ location: "http://localhost:5173" }, 5173, "GID");
  assert.equal(out.location, "/forward/GID/");
});

test("a FOREIGN Location passes through untouched", () => {
  const out = rewriteResponseHeaders(
    { location: "https://github.com/login/oauth" },
    5173,
    "GID",
  );
  assert.equal(out.location, "https://github.com/login/oauth");
});

test("a Location on a DIFFERENT loopback port is left alone", () => {
  const out = rewriteResponseHeaders({ location: "http://127.0.0.1:4173/x" }, 5173, "GID");
  assert.equal(out.location, "http://127.0.0.1:4173/x");
});

test("Set-Cookie loses Domain and Secure, keeps everything else", () => {
  const out = rewriteResponseHeaders(
    {
      "set-cookie": [
        "sid=1; Domain=127.0.0.1; Path=/; HttpOnly; Secure; SameSite=Lax",
        "other=2; Path=/api",
      ],
    },
    5173,
    "GID",
  );
  assert.deepEqual(out["set-cookie"], [
    "sid=1; Path=/; HttpOnly; SameSite=Lax",
    "other=2; Path=/api",
  ]);
});

test("hop-by-hop response headers are dropped", () => {
  const out = rewriteResponseHeaders(
    { connection: "keep-alive", "transfer-encoding": "chunked", "content-type": "text/html" },
    5173,
    "GID",
  );
  assert.equal(out.connection, undefined);
  assert.equal(out["transfer-encoding"], undefined);
  assert.equal(out["content-type"], "text/html");
});

// ── browser mode: the URL is the credential (system-browser hand-off) ──────

test("a BROWSER grant is served with no bearer at all", async () => {
  // Safari cannot set an Authorization header, so a grant minted for the system
  // browser authorises on its id alone.
  const h = await harness();
  try {
    const g = h.grants.mint({
      deviceId: DEVICE.id,
      port: h.devPort,
      worktreePath: "/wt",
      browser: true,
    });
    const res = await fetch(`${h.base}/forward/${g.grantId}/index.html`);
    assert.equal(res.status, 200);
    assert.match(await res.text(), /dev says GET \/index\.html/);
  } finally {
    await h.stop();
  }
});

test("a STRICT grant is still refused without a bearer", async () => {
  // The browser path must not soften the default one.
  const h = await harness();
  try {
    const g = h.grants.mint({ deviceId: DEVICE.id, port: h.devPort, worktreePath: "/wt" });
    assert.equal((await fetch(`${h.base}/forward/${g.grantId}/`)).status, 401);
    assert.equal(h.seen.length, 0);
  } finally {
    await h.stop();
  }
});

test("an INVALID bearer is 401 even for a browser grant", async () => {
  // A wrong credential is a different fault from no credential: it means a stale
  // pairing, and saying 403 would send the app looking for the wrong problem.
  const h = await harness();
  try {
    const g = h.grants.mint({
      deviceId: DEVICE.id,
      port: h.devPort,
      worktreePath: "/wt",
      browser: true,
    });
    const res = await fetch(`${h.base}/forward/${g.grantId}/`, {
      headers: { authorization: "Bearer wrong" },
    });
    assert.equal(res.status, 401);
  } finally {
    await h.stop();
  }
});

test("an unknown grant with no bearer is 403, not 401", async () => {
  const h = await harness();
  try {
    const res = await fetch(`${h.base}/forward/deadbeef/`);
    assert.equal(res.status, 403);
  } finally {
    await h.stop();
  }
});

test("every proxied response carries Referrer-Policy: no-referrer", async () => {
  // In browser mode the URL is the credential, so a link on the previewed page to
  // any external site would otherwise hand the grant to that site in `Referer`.
  const h = await harness();
  try {
    const g = h.grants.mint({
      deviceId: DEVICE.id,
      port: h.devPort,
      worktreePath: "/wt",
      browser: true,
    });
    const res = await fetch(`${h.base}/forward/${g.grantId}/`);
    assert.equal(res.headers.get("referrer-policy"), "no-referrer");
  } finally {
    await h.stop();
  }
});

test("an upstream Referrer-Policy cannot override ours", async () => {
  const h = await harness((_, res) => {
    res.writeHead(200, { "referrer-policy": "unsafe-url" });
    res.end("x");
  });
  try {
    const g = h.grants.mint({
      deviceId: DEVICE.id,
      port: h.devPort,
      worktreePath: "/wt",
      browser: true,
    });
    const res = await fetch(`${h.base}/forward/${g.grantId}/`);
    assert.equal(res.headers.get("referrer-policy"), "no-referrer");
  } finally {
    await h.stop();
  }
});
