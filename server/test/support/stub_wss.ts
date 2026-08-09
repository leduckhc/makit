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
  /** Pushed as a `projects.snapshot` event right after `hello.ack`. */
  projects?: unknown[];
  /**
   * `SessionEvent`s replayed on `sub`, oldest-first, filtered by `fromSeq`
   * exactly as the real `SubscriptionHub` does, then followed by the `sub` ack.
   * Each is framed as the server frames it: `{t:"event", kind:"session.event"}`.
   */
  events?: { seq: number; sessionId: string; [k: string]: unknown }[];
  /** When set, a `sub` is answered with an `err` frame (e.g. `no_such_session`). */
  subErr?: string;
  /**
   * Called for each `cmd` frame; returns the ack payload to merge into the
   * reply. Return `{ __err: "message" }` to answer with an `err` frame instead
   * (e.g. `no_such_session`), which is how a plain command failure is tested.
   */
  onCmd?: (m: Record<string, unknown>) => Record<string, unknown>;
}

export interface StubWss {
  port: number;
  /** Push one live `session.event` to every connected client (for `tail -f`). */
  push: (event: Record<string, unknown>) => void;
  close: () => Promise<void>;
}

/**
 * One self-signed key pair per test process. RSA keygen is slow and occasionally
 * takes seconds, and a fresh cert per stub added that cost to every CLI test —
 * the client does not verify it anyway (loopback, `rejectUnauthorized: false`).
 */
let pemsOnce: Promise<{ cert: string; private: string }> | undefined;
function testPems(): Promise<{ cert: string; private: string }> {
  pemsOnce ??= selfsigned.generate([{ name: "commonName", value: "makit" }], {
    keySize: 2048,
    algorithm: "sha256",
  });
  return pemsOnce;
}

export async function startStubWss(opts: StubWssOpts = {}): Promise<StubWss> {
  const pems = await testPems();
  const https: Server = createServer({ cert: pems.cert, key: pems.private });
  const wss = new WebSocketServer({ server: https });
  const live = new Set<WsSocket>();
  wss.on("connection", (ws: WsSocket) => {
    live.add(ws);
    ws.on("close", () => live.delete(ws));
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
        if (opts.projects) {
          ws.send(JSON.stringify({ t: "event", id: "psnap", kind: "projects.snapshot", projects: opts.projects }));
        }
        if (opts.sessions) {
          ws.send(JSON.stringify({ t: "event", id: "snap", kind: "sessions.snapshot", sessions: opts.sessions }));
        }
        return;
      }
      if (m.t === "sub") {
        if (opts.subErr !== undefined) {
          ws.send(JSON.stringify({ t: "err", id: m.id, code: "no_such_session", message: opts.subErr }));
          return;
        }
        // Replay history oldest-first, filtered by fromSeq, then ack — the exact
        // order `SubscriptionHub.handleSub` uses, so the client can key "replay
        // complete" off the ack.
        const fromSeq = typeof m.fromSeq === "number" ? m.fromSeq : 0;
        for (const e of opts.events ?? []) {
          if (e.sessionId !== m.sessionId) continue;
          if (fromSeq > 0 && e.seq <= fromSeq) continue;
          ws.send(JSON.stringify({ t: "event", id: `ev${e.seq}`, kind: "session.event", event: e }));
        }
        ws.send(JSON.stringify({ t: "ack", id: m.id }));
        return;
      }
      if (m.t === "cmd") {
        const extra = opts.onCmd ? opts.onCmd(m) : {};
        if (typeof extra.__err === "string") {
          ws.send(JSON.stringify({ t: "err", id: m.id, code: "no_such_session", message: extra.__err }));
          return;
        }
        ws.send(JSON.stringify({ t: "ack", id: m.id, ...extra }));
        return;
      }
    });
  });
  await new Promise<void>((resolve) => https.listen(0, "127.0.0.1", resolve));
  const port = (https.address() as AddressInfo).port;
  return {
    port,
    push: (event) => {
      const frame = JSON.stringify({ t: "event", id: `ev-${Date.now()}`, kind: "session.event", event });
      for (const ws of live) ws.send(frame);
    },
    close: () =>
      new Promise<void>((resolve) => {
        for (const ws of live) ws.terminate();
        wss.close(() => https.close(() => resolve()));
      }),
  };
}
