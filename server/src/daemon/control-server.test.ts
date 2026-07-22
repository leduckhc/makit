/**
 * Control-server tests (SPEC-01, phase 2).
 *
 * The server is transport (a unix socket) + a pure request dispatcher. We test
 * the dispatcher against a fake backend (fast, no sockets) and the socket
 * wiring against a real temp-dir socket (perms, connectivity, framing).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { connect } from "node:net";

import {
  dispatchRequest,
  createControlServer,
  type ControlBackend,
} from "./control-server.js";
import {
  encodeMessage,
  decodeResponse,
  LineBuffer,
  type ControlRequest,
  type ControlResponse,
} from "./protocol.js";

function fakeBackend(over: Partial<ControlBackend> = {}): ControlBackend {
  return {
    status: () => ({
      pid: 1,
      uptimeMs: 10,
      host: "0.0.0.0",
      port: 7788,
      fingerprint: "fp",
      advertiseHost: "192.168.1.2",
      pairedDevices: 0,
      runningSessions: 0,
      version: "0.1.0",
    }),
    pairMint: (args) => ({
      url: "makit://pair?t=x",
      token: "x",
      expiresAt: 100 + (args.ttlMs ?? 0),
      fingerprint: "fp",
    }),
    pairCurrent: () => null,
    devicesList: () => ({ devices: [] }),
    devicesRevoke: (args) => ({ removed: args.id === "known" }),
    sessionsList: () => ({ sessions: [] }),
    serverStop: () => ({ stopping: true }),
    logsTail: (_args, emit) => {
      emit("line-1");
      emit("line-2");
    },
    ...over,
  };
}

async function collect(req: ControlRequest, backend: ControlBackend): Promise<ControlResponse[]> {
  const out: ControlResponse[] = [];
  await dispatchRequest(req, backend, (m) => out.push(m));
  return out;
}

test("dispatch: status verb returns backend status", async () => {
  const [res] = await collect({ id: "1", verb: "status" }, fakeBackend());
  assert.equal(res!.ok, true);
  assert.equal((res as { data: { port: number } }).data.port, 7788);
});

test("dispatch: pair.mint forwards ttlMs args", async () => {
  const [res] = await collect(
    { id: "2", verb: "pair.mint", args: { ttlMs: 5 } },
    fakeBackend(),
  );
  assert.equal((res as { data: { expiresAt: number } }).data.expiresAt, 105);
});

test("dispatch: devices.revoke forwards id", async () => {
  const [hit] = await collect(
    { id: "3", verb: "devices.revoke", args: { id: "known" } },
    fakeBackend(),
  );
  assert.equal((hit as { data: { removed: boolean } }).data.removed, true);
});

test("dispatch: a throwing backend yields an error response, never throws", async () => {
  const backend = fakeBackend({
    status: () => {
      throw new Error("kaboom");
    },
  });
  const [res] = await collect({ id: "4", verb: "status" }, backend);
  assert.deepEqual(res, { id: "4", ok: false, error: "kaboom" });
});

test("dispatch: logs.tail without follow emits line chunks then a done chunk", async () => {
  const out = await collect({ id: "5", verb: "logs.tail" }, fakeBackend());
  assert.deepEqual(out, [
    { id: "5", ok: true, data: { line: "line-1" } },
    { id: "5", ok: true, data: { line: "line-2" } },
    { id: "5", ok: true, data: { done: true } },
  ]);
});

test("dispatch: logs.tail with follow streams lines and returns a stop fn (no done)", async () => {
  let stopped = false;
  const backend = fakeBackend({
    logsTail: (_args, emit) => {
      emit("backlog");
      return () => {
        stopped = true;
      };
    },
  });
  const out: ControlResponse[] = [];
  const stop = await dispatchRequest(
    { id: "6", verb: "logs.tail", args: { follow: true } },
    backend,
    (m) => out.push(m),
  );
  assert.deepEqual(out, [{ id: "6", ok: true, data: { line: "backlog" } }]);
  assert.equal(typeof stop, "function");
  stop!();
  assert.equal(stopped, true);
});

async function withSocket(fn: (path: string) => Promise<void>) {
  const dir = mkdtempSync(join(tmpdir(), "makit-ctl-"));
  const path = join(dir, "control.sock");
  const handle = await createControlServer({ socketPath: path, backend: fakeBackend() });
  try {
    await fn(path);
  } finally {
    await handle.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

test("socket: logs.cancel stops one followed log tail", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-ctl-"));
  const path = join(dir, "control.sock");
  let stopped = false;
  const handle = await createControlServer({
    socketPath: path,
    backend: fakeBackend({
      logsTail: (_args, emit) => {
        emit("line-1");
        return () => {
          stopped = true;
        };
      },
    }),
  });
  try {
    const cancel = await new Promise<ControlResponse>((resolve, reject) => {
      const sock = connect(path);
      const buf = new LineBuffer();
      sock.on("connect", () =>
        sock.write(encodeMessage({ id: "tail-1", verb: "logs.tail", args: { follow: true } })),
      );
      sock.on("data", (d) => {
        for (const line of buf.push(d.toString())) {
          const res = decodeResponse(line);
          if (!res) continue;
          if (res.id === "tail-1") {
            setImmediate(() =>
              sock.write(
                encodeMessage({
                  id: "cancel-1",
                  verb: "logs.cancel",
                  args: { id: "tail-1" },
                }),
              ),
            );
          }
          if (res.id === "cancel-1") {
            sock.end();
            resolve(res);
          }
        }
      });
      sock.on("error", reject);
    });
    assert.deepEqual(cancel, { id: "cancel-1", ok: true, data: { cancelled: true } });
    assert.equal(stopped, true);
  } finally {
    await handle.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("socket: logs.cancel reports false for a stale log-tail id", async () => {
  await withSocket(async (path) => {
    const cancel = await new Promise<ControlResponse>((resolve, reject) => {
      const sock = connect(path);
      const buf = new LineBuffer();
      sock.on("connect", () =>
        sock.write(
          encodeMessage({
            id: "cancel-stale",
            verb: "logs.cancel",
            args: { id: "missing-tail" },
          }),
        ),
      );
      sock.on("data", (d) => {
        for (const line of buf.push(d.toString())) {
          const res = decodeResponse(line);
          if (res?.id === "cancel-stale") {
            sock.end();
            resolve(res);
          }
        }
      });
      sock.on("error", reject);
    });
    assert.deepEqual(cancel, {
      id: "cancel-stale",
      ok: true,
      data: { cancelled: false },
    });
  });
});

test("socket: created 0600 and answers a request end-to-end", async () => {
  await withSocket(async (path) => {
    const mode = statSync(path).mode & 0o777;
    assert.equal(mode, 0o600);

    const res = await new Promise<ControlResponse>((resolve, reject) => {
      const sock = connect(path);
      const buf = new LineBuffer();
      sock.on("connect", () => sock.write(encodeMessage({ id: "9", verb: "status" })));
      sock.on("data", (d) => {
        for (const line of buf.push(d.toString())) {
          const r = decodeResponse(line);
          if (r) {
            sock.end();
            resolve(r);
          }
        }
      });
      sock.on("error", reject);
    });
    assert.equal(res.id, "9");
    assert.equal(res.ok, true);
  });
});

test("socket: malformed line yields an error response and keeps the connection", async () => {
  await withSocket(async (path) => {
    const res = await new Promise<ControlResponse>((resolve, reject) => {
      const sock = connect(path);
      const buf = new LineBuffer();
      sock.on("connect", () => sock.write("{ garbage\n"));
      sock.on("data", (d) => {
        for (const line of buf.push(d.toString())) {
          const r = decodeResponse(line);
          if (r) {
            sock.end();
            resolve(r);
          }
        }
      });
      sock.on("error", reject);
    });
    assert.equal(res.ok, false);
  });
});

test("createControlServer refuses to start when a live daemon answers the probe", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-ctl-"));
  const path = join(dir, "control.sock");
  try {
    await assert.rejects(
      () =>
        createControlServer({
          socketPath: path,
          backend: fakeBackend(),
          probe: async () => true, // a live daemon is already listening
        }),
      /already listening/,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("createControlServer binds when the probe reports a stale socket file", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-ctl-"));
  const path = join(dir, "control.sock");
  // Simulate a leftover file from a crashed daemon.
  writeFileSync(path, "stale");
  let probed = "";
  const handle = await createControlServer({
    socketPath: path,
    backend: fakeBackend(),
    probe: async (p) => {
      probed = p;
      return false; // nothing alive → safe to unlink + rebind
    },
  });
  try {
    assert.equal(probed, path);
    assert.equal(statSync(path).mode & 0o777, 0o600); // rebound as a fresh 0600 socket
  } finally {
    await handle.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("socket: an over-cap unterminated line is rejected and the connection closed", async () => {
  await withSocket(async (path) => {
    const result = await new Promise<{ res: ControlResponse | null; closed: boolean }>(
      (resolve, reject) => {
        const sock = connect(path);
        const buf = new LineBuffer(64 * 1024 * 1024); // client buffer must not trip first
        let res: ControlResponse | null = null;
        sock.on("connect", () => sock.write("x".repeat(1024 * 1024 + 1))); // no newline, > 1 MiB
        sock.on("data", (d) => {
          for (const line of buf.push(d.toString())) {
            const r = decodeResponse(line);
            if (r) res = r;
          }
        });
        sock.on("close", () => resolve({ res, closed: true }));
        sock.on("error", reject);
      },
    );
    assert.equal(result.closed, true);
    assert.equal(result.res?.ok, false);
  });
});
