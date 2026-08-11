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
   * `srv.request` envelopes pushed to a subscribing client right after the
   * `sub` ack — the order the real server uses (`server.ts:698`-`701`:
   * `handleSub` acks, then `rpc.replayPendingTo` re-sends the pending prompt).
   * Sent verbatim and unconditionally, so a test can exercise both the happy
   * path (matching `sessionId`) and the D13(b) client-side lock (a prompt for
   * a session the client did not name).
   */
  srvRequests?: Record<string, unknown>[];
  /**
   * Answer `POST /media` (SPEC-33) with this `mediaId`, recording each upload on
   * {@link StubWss.uploads}. Media rides the same HTTPS listener as the socket on
   * the real server, so the stub serves it from the same place.
   */
  mediaId?: string;
  /**
   * Accept `POST /media` and then never answer it — an overloaded or wedged
   * server. The request is recorded on {@link StubWss.uploads} as usual, so a
   * test can prove the upload was attempted and still timed out.
   */
  mediaStall?: boolean;
  /**
   * Called for each `cmd` frame; returns the ack payload to merge into the
   * reply. Return `{ __err: "message" }` to answer with an `err` frame instead
   * (e.g. `no_such_session`), which is how a plain command failure is tested.
   */
  onCmd?: (m: Record<string, unknown>) => Record<string, unknown>;
}

export interface StubWss {
  port: number;
  /** One entry per `POST /media`, in arrival order. */
  uploads: { mime: string; auth?: string; bytes: number }[];
  /** Every `srv.response` frame a client sent, in arrival order. */
  responses: Record<string, unknown>[];
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
  const uploads: { mime: string; auth?: string; bytes: number }[] = [];
  const responses: Record<string, unknown>[] = [];
  https.on("request", (req, res) => {
    if (req.method !== "POST" || (req.url ?? "").split("?")[0] !== "/media") return;
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      const mime = String(req.headers["content-type"] ?? "");
      uploads.push({ mime, auth: req.headers.authorization, bytes: body.length });
      if (opts.mediaStall) return; // accepted, never answered
      if (opts.mediaId === undefined) {
        res.writeHead(415, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "unsupported_media_type" }));
        return;
      }
      res.writeHead(201, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ mediaId: opts.mediaId, mime, sizeBytes: body.length }));
    });
  });
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
        for (const req of opts.srvRequests ?? []) {
          ws.send(JSON.stringify({ t: "srv.request", ...req }));
        }
        return;
      }
      if (m.t === "srv.response") {
        responses.push(m);
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
    uploads,
    responses,
    push: (event) => {
      const frame = JSON.stringify({ t: "event", id: `ev-${Date.now()}`, kind: "session.event", event });
      for (const ws of live) ws.send(frame);
    },
    close: () =>
      new Promise<void>((resolve) => {
        for (const ws of live) ws.terminate();
        // `server.close()` stops accepting but WAITS for connections that are still
        // open, and a test may deliberately leave a request unanswered — that is
        // exactly what `mediaStall` is for. Without forcing the sockets shut, such
        // a test wedges teardown, and because the whole file then never finishes,
        // the symptom is a suite that goes silent until CI's job timeout kills it
        // rather than a failing assertion anyone can read.
        https.closeAllConnections();
        wss.close(() => https.close(() => resolve()));
      }),
  };
}
