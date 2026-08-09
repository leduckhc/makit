/**
 * A throwaway WSS server that speaks makit's client envelope (SPEC-46).
 *
 * Test-only support module (not a `*.test.ts`, so the runner does not pick it
 * up). It exists because every CLI verb is a client of `cli/client.ts`, and each
 * of their tests needs the same three behaviours: accept-or-reject a `hello`,
 * push a `sessions.snapshot`, and ack a `cmd`.
 */
import { createServer, type Server } from "node:https";
import { WebSocketServer, type WebSocket as WsSocket } from "ws";
import type { AddressInfo } from "node:net";
import selfsigned from "selfsigned";

export interface StubWssOpts {
  /** When set, a `hello` whose bearer differs is rejected (err + close 4401). */
  acceptBearer?: string;
  /** Pushed as a `sessions.snapshot` event right after `hello.ack`. */
  sessions?: unknown[];
  /** Called for each `cmd` frame; returns the ack payload to merge into the reply. */
  onCmd?: (m: Record<string, unknown>) => Record<string, unknown>;
}

export interface StubWss {
  port: number;
  close: () => Promise<void>;
}

export async function startStubWss(opts: StubWssOpts = {}): Promise<StubWss> {
  const pems = await selfsigned.generate([{ name: "commonName", value: "makit" }], {
    keySize: 2048,
    algorithm: "sha256",
  });
  const https: Server = createServer({ cert: pems.cert, key: pems.private });
  const wss = new WebSocketServer({ server: https });
  wss.on("connection", (ws: WsSocket) => {
    ws.on("message", (buf: Buffer) => {
      let m: Record<string, unknown>;
      try {
        m = JSON.parse(buf.toString());
      } catch {
        return;
      }
      if (m.t === "hello") {
        if (opts.acceptBearer !== undefined && m.bearer !== opts.acceptBearer) {
          ws.send(JSON.stringify({ t: "err", id: m.id, code: "unauthorized", message: "unknown device" }));
          ws.close(4401, "unauthorized");
          return;
        }
        ws.send(JSON.stringify({ t: "hello.ack", id: m.id, ok: true, deviceId: "d1" }));
        if (opts.sessions) {
          ws.send(JSON.stringify({ t: "event", id: "snap", kind: "sessions.snapshot", sessions: opts.sessions }));
        }
        return;
      }
      if (m.t === "cmd") {
        const extra = opts.onCmd ? opts.onCmd(m) : {};
        ws.send(JSON.stringify({ t: "ack", id: m.id, ...extra }));
        return;
      }
    });
  });
  await new Promise<void>((resolve) => https.listen(0, "127.0.0.1", resolve));
  const port = (https.address() as AddressInfo).port;
  return {
    port,
    close: () =>
      new Promise<void>((resolve) => {
        wss.close(() => https.close(() => resolve()));
      }),
  };
}
