import assert from "node:assert/strict";
import { test } from "node:test";

import {
  PortHealthProbe,
  NO_HTTP_PROBE_PORTS,
  PROBE_TIMEOUT_MS,
  PROBE_TTL_MS,
  PROBE_CONCURRENCY,
  MAX_STATUS_LINE_BYTES,
  type Connector,
  type ProbeSocket,
} from "./health.js";
import type { PortDTO } from "../protocol.js";

/** A scripted socket: emits data / error / close on demand, records writes. */
class FakeSocket implements ProbeSocket {
  writes: string[] = [];
  destroyed = false;
  private handlers: Record<string, ((arg?: unknown) => void)[]> = {};
  write(data: string): void {
    this.writes.push(data);
  }
  on(event: "data", cb: (chunk: string) => void): void;
  on(event: "error", cb: (err: NodeJS.ErrnoException) => void): void;
  on(event: "close", cb: () => void): void;
  on(event: string, cb: (...args: never[]) => void): void {
    (this.handlers[event] ??= []).push(cb as (arg?: unknown) => void);
  }
  destroy(): void {
    this.destroyed = true;
  }
  emit(event: string, arg?: unknown): void {
    for (const cb of this.handlers[event] ?? []) cb(arg);
  }
}

/** Controllable timer + clock so no test waits on the wall clock. */
function fakeClock() {
  const timers: { fn: () => void; cancelled: boolean }[] = [];
  let nowMs = 1_000;
  return {
    now: () => nowMs,
    advance: (ms: number) => {
      nowMs += ms;
    },
    setTimer: (fn: () => void) => {
      const h = { fn, cancelled: false };
      timers.push(h);
      return h;
    },
    clearTimer: (h: unknown) => {
      (h as { cancelled: boolean }).cancelled = true;
    },
    fire: () => {
      for (const t of timers) if (!t.cancelled) t.fn();
    },
  };
}

function ownedPort(over: Partial<PortDTO> = {}): PortDTO {
  return {
    key: "1:127.0.0.1:5173",
    port: 5173,
    address: "127.0.0.1",
    reach: "loopback",
    pid: 1,
    command: "node",
    worktreePath: "/repo/wt-a",
    ...over,
  };
}

/** Flush pending microtasks so mapLimit's async workers reach their connect(). */
const flush = () => new Promise((r) => setImmediate(r));

test("200 → ok + status", async () => {
  const clock = fakeClock();
  const sock = new FakeSocket();
  const connector: Connector = () => sock;
  const probe = new PortHealthProbe({ connect: connector, ...clock });
  const p = probe.refresh([ownedPort()]);
  await flush();
  sock.emit("data", "HTTP/1.1 200 OK\r\n");
  await p;
  const v = probe.verdict("127.0.0.1", 5173);
  assert.equal(v?.kind, "ok");
  assert.equal(v?.status, 200);
  assert.equal(v?.probedAt, clock.now());
  assert.match(sock.writes[0] ?? "", /^GET \/ HTTP\/1\.1/);
  assert.match(sock.writes[0] ?? "", /Connection: close/);
});

test("404 → http-error + status", async () => {
  const clock = fakeClock();
  const sock = new FakeSocket();
  const probe = new PortHealthProbe({ connect: () => sock, ...clock });
  const p = probe.refresh([ownedPort()]);
  await flush();
  sock.emit("data", "HTTP/1.1 404 Not Found\r\nX: y\r\n");
  await p;
  const v = probe.verdict("127.0.0.1", 5173);
  assert.equal(v?.kind, "http-error");
  assert.equal(v?.status, 404);
});

test("ECONNREFUSED → refused", async () => {
  const clock = fakeClock();
  const sock = new FakeSocket();
  const probe = new PortHealthProbe({ connect: () => sock, ...clock });
  const p = probe.refresh([ownedPort()]);
  await flush();
  const err: NodeJS.ErrnoException = new Error("connect ECONNREFUSED");
  err.code = "ECONNREFUSED";
  sock.emit("error", err);
  await p;
  assert.equal(probe.verdict("127.0.0.1", 5173)?.kind, "refused");
});

test("a hang → timeout at PROBE_TIMEOUT_MS", async () => {
  const clock = fakeClock();
  const sock = new FakeSocket(); // never emits
  const probe = new PortHealthProbe({ connect: () => sock, ...clock });
  const p = probe.refresh([ownedPort()]);
  await flush();
  clock.fire(); // the PROBE_TIMEOUT_MS timer elapses
  await p;
  assert.equal(probe.verdict("127.0.0.1", 5173)?.kind, "timeout");
  assert.ok(sock.destroyed, "the socket is torn down on timeout");
  assert.ok(PROBE_TIMEOUT_MS === 800);
});

test("a malformed status line is http-error, not a throw", async () => {
  const clock = fakeClock();
  const sock = new FakeSocket();
  const probe = new PortHealthProbe({ connect: () => sock, ...clock });
  const p = probe.refresh([ownedPort()]);
  await flush();
  sock.emit("data", "<html>not http</html>\r\n");
  await p;
  assert.equal(probe.verdict("127.0.0.1", 5173)?.kind, "http-error");
});

test("an unowned port (no worktreePath) is NEVER probed", async () => {
  const clock = fakeClock();
  let connected = false;
  const probe = new PortHealthProbe({
    connect: () => {
      connected = true;
      return new FakeSocket();
    },
    ...clock,
  });
  await probe.refresh([ownedPort({ worktreePath: undefined })]);
  assert.equal(connected, false);
});

test("a deny-listed port (e.g. 5432 postgres) is NEVER probed", async () => {
  const clock = fakeClock();
  let connected = false;
  const probe = new PortHealthProbe({
    connect: () => {
      connected = true;
      return new FakeSocket();
    },
    ...clock,
  });
  assert.ok(NO_HTTP_PROBE_PORTS.includes(5432));
  await probe.refresh([ownedPort({ port: 5432 })]);
  assert.equal(connected, false);
});

test("a concrete non-loopback address (no loopback form) is NEVER probed", async () => {
  const clock = fakeClock();
  let connected = false;
  const probe = new PortHealthProbe({
    connect: () => {
      connected = true;
      return new FakeSocket();
    },
    ...clock,
  });
  await probe.refresh([ownedPort({ address: "100.119.58.97", reach: "tailnet" })]);
  assert.equal(connected, false);
});

test("a wildcard bind IS probed, on its loopback form 127.0.0.1", async () => {
  const clock = fakeClock();
  let host: string | undefined;
  const sock = new FakeSocket();
  const probe = new PortHealthProbe({
    connect: (h) => {
      host = h;
      return sock;
    },
    ...clock,
  });
  const p = probe.refresh([ownedPort({ address: "*" })]);
  await flush();
  sock.emit("data", "HTTP/1.1 200 OK\r\n");
  await p;
  assert.equal(host, "127.0.0.1");
  assert.equal(probe.verdict("*", 5173)?.kind, "ok");
});

test("a verdict is cached for PROBE_TTL_MS, then re-probed", async () => {
  const clock = fakeClock();
  let connects = 0;
  const makeProbe = () =>
    new PortHealthProbe({
      connect: () => {
        connects++;
        const s = new FakeSocket();
        queueMicrotask(() => s.emit("data", "HTTP/1.1 200 OK\r\n"));
        return s;
      },
      ...clock,
    });
  const probe = makeProbe();
  await probe.refresh([ownedPort()]);
  assert.equal(connects, 1);
  // Within TTL: no re-probe.
  await probe.refresh([ownedPort()]);
  assert.equal(connects, 1);
  // Past TTL: re-probe.
  clock.advance(PROBE_TTL_MS + 1);
  await probe.refresh([ownedPort()]);
  assert.equal(connects, 2);
});

test("the concurrency cap is respected", async () => {
  const clock = fakeClock();
  let active = 0;
  let peak = 0;
  const sockets: FakeSocket[] = [];
  const probe = new PortHealthProbe({
    connect: () => {
      active++;
      peak = Math.max(peak, active);
      const s = new FakeSocket();
      const done = s.destroy.bind(s);
      s.destroy = () => {
        active--;
        done();
      };
      sockets.push(s);
      return s;
    },
    ...clock,
  });
  const ports = Array.from({ length: PROBE_CONCURRENCY * 2 }, (_, i) =>
    ownedPort({ port: 6000 + i, key: `1:127.0.0.1:${6000 + i}` }),
  );
  const p = probe.refresh(ports);
  await flush();
  assert.ok(peak <= PROBE_CONCURRENCY, `peak ${peak} exceeded cap ${PROBE_CONCURRENCY}`);
  // Drain: resolve every outstanding probe until refresh settles (workers pick up
  // the next port only as earlier ones complete).
  let settled = false;
  void p.then(() => {
    settled = true;
  });
  // Cap the drain so a future change in health.ts that stops settling FAILS this
  // test with a clear message instead of hanging the whole run (finding 18).
  let drains = 0;
  const MAX_DRAINS = PROBE_CONCURRENCY * 4;
  while (!settled) {
    assert.ok(drains++ < MAX_DRAINS, "refresh did not settle after draining every probe");
    for (const s of sockets) s.emit("data", "HTTP/1.1 200 OK\r\n");
    await flush();
  }
  await p;
});

test("a vanished endpoint's verdict is pruned once it no longer listens (finding 19)", async () => {
  const clock = fakeClock();
  const connect = () => {
    const s = new FakeSocket();
    queueMicrotask(() => s.emit("data", "HTTP/1.1 200 OK\r\n"));
    return s;
  };
  const probe = new PortHealthProbe({ connect, ...clock });
  await probe.refresh([ownedPort()]); // 127.0.0.1:5173 probed + cached
  assert.ok(probe.verdict("127.0.0.1", 5173), "cached after the first probe");
  // Next scan: :5173 is gone, only :6000 listens now. The stale verdict must be
  // dropped rather than accumulate for the process lifetime.
  await probe.refresh([ownedPort({ port: 6000, key: "1:127.0.0.1:6000" })]);
  assert.equal(probe.verdict("127.0.0.1", 5173), undefined, "the vanished endpoint is pruned");
  assert.ok(probe.verdict("127.0.0.1", 6000), "the still-listening endpoint remains");
});

test("an over-long status line (no newline within MAX_STATUS_LINE_BYTES) is http-error, not an unbounded read", async () => {
  const clock = fakeClock();
  const sock = new FakeSocket();
  const probe = new PortHealthProbe({ connect: () => sock, ...clock });
  const p = probe.refresh([ownedPort()]);
  await flush();
  sock.emit("data", "x".repeat(MAX_STATUS_LINE_BYTES + 1)); // streams past the bound, no newline
  await p;
  assert.equal(probe.verdict("127.0.0.1", 5173)?.kind, "http-error");
  assert.ok(sock.destroyed, "the socket is torn down, not left growing a buffer");
});

test("refresh never throws even if the connector itself throws", async () => {
  const clock = fakeClock();
  const probe = new PortHealthProbe({
    connect: () => {
      throw new Error("connect blew up");
    },
    ...clock,
  });
  await probe.refresh([ownedPort()]); // must resolve, not reject
  assert.equal(probe.verdict("127.0.0.1", 5173)?.kind, "refused");
});
