/**
 * WebSocket server with TLS + auth — thin wiring over four collaborators:
 *
 *   - {@link AuthGate}         — the `hello` handshake + auth decision.
 *   - {@link SubscriptionHub}  — `sub`/`unsub` + session-event fan-out.
 *   - {@link CommandRouter}    — OCP registry for `cmd` frames.
 *   - {@link ReverseRpc}       — `srv.request`/`srv.response` (askDevice).
 *
 * Auth model:
 *   - First frame on every connection must be a `hello`.
 *   - hello.bearer → long-lived paired-device token; if it matches a known
 *     device, we're authenticated.
 *   - hello.pair   → short-lived QR pair token; on success the server mints a
 *     new device and returns its bearer in `hello.ack.bearer`.
 *   - Anything else → close with 4401 (unauthorized).
 *
 * Localhost connections (loopback remote address) can opt out of auth via
 * `--no-auth` — useful for the `flutter run -d macos` dev loop. By default
 * even localhost is gated so behaviour matches production.
 *
 * All incoming frames are validated through the wire codec (`decodeFrame`);
 * malformed input yields an `err {code: bad_request}` and is never thrown.
 */

import { createServer as createHttpsServer, type Server as HttpsServer } from "node:https";
import { WebSocketServer, type WebSocket } from "ws";
import type { Envelope } from "./protocol.js";
import { PROTOCOL_VERSION, newId } from "./protocol.js";
import { decodeFrame, encodeFrame, WireErrorCode } from "./protocol/codec.js";
import type { SessionManager } from "./manager.js";
import type { Session } from "./session.js";
import type { DeviceRegistry } from "./pairing/registry.js";
import type { ServerCert } from "./pairing/cert.js";
import { log } from "./log.js";
import type { OutgoingFrame, WsClient } from "./ws/client.js";
import { AuthGate } from "./ws/auth_gate.js";
import { SubscriptionHub } from "./ws/subscription_hub.js";
import { CommandRouter } from "./ws/command_router.js";
import { ReverseRpc } from "./ws/reverse_rpc.js";

export interface ServerOpts {
  host: string;
  port: number;
  manager: SessionManager;
  cert: ServerCert;
  registry: DeviceRegistry;
  /** If true, accept loopback connections without auth. */
  trustLocalhost?: boolean;
}

/** Concrete client: a {@link WsClient} backed by a live `ws` socket. */
interface ClientState extends WsClient {
  ws: WebSocket;
}

export function startWsServer(opts: ServerOpts) {
  const { host, port, manager, cert, registry, trustLocalhost = false } = opts;

  const https: HttpsServer = createHttpsServer({ cert: cert.cert, key: cert.key });
  const wss = new WebSocketServer({ server: https });
  https.on("tlsClientError", (err: Error, sock) => {
    log.warn(`[pino] TLS client error from ${sock.remoteAddress ?? "?"}: ${err.message}`);
  });
  wss.on("error", (err: Error) => {
    log.error(`[pino] wss error: ${err.message}`);
  });

  const clients = new Map<WebSocket, ClientState>();

  // -------- collaborators -------------------------------------------------

  const hub = new SubscriptionHub({ manager });
  const rpc = new ReverseRpc({ clients: () => clients.values() });
  const authGate = new AuthGate({ registry, onAuthenticated: sendSnapshots });
  const router = buildCommandRouter();

  // -------- session wiring ------------------------------------------------

  for (const s of manager.allSessions()) wireSession(s);
  // Also wire any sessions created later (e.g. via ensureDefaultSessions which
  // runs after startWsServer, or via the session.spawn cmd handler).
  manager.on("sessionCreated", (s: Session) => wireSession(s));

  // -------- connection lifecycle ------------------------------------------

  wss.on("connection", (ws, req) => {
    const remote = req.socket.remoteAddress ?? "";
    log.info(`[pino] ws connection from ${remote}`);
    const isLocal = remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
    const state = makeClient(ws, trustLocalhost && isLocal);
    clients.set(ws, state);
    hub.register(state);

    ws.on("message", (raw) => {
      const env = decodeFrame(raw.toString());
      if (!env) {
        state.send({ t: "err", id: "", code: WireErrorCode.BadRequest, message: "malformed frame" });
        return;
      }
      handleEnvelope(state, env);
    });

    ws.on("close", () => {
      clients.delete(ws);
      hub.unregister(state);
    });

    if (state.authed) sendSnapshots(state);
  });

  https.listen(port, host, () => {
    log.info(`[pino] wss listening on wss://${host}:${port}`);
  });

  const askDevice = rpc.askDevice.bind(rpc);
  return { wss, https, askDevice };

  // -------- dispatch ------------------------------------------------------

  function handleEnvelope(state: ClientState, env: Envelope) {
    // The only thing an unauthed client may send is `hello`.
    if (!state.authed && env.t !== "hello") {
      state.send({ t: "err", id: env.id, code: WireErrorCode.Unauthorized, message: "unauthorized" });
      state.ws.close(4401, "unauthorized");
      return;
    }

    switch (env.t) {
      case "hello":
        authGate.handleHello(state, env);
        return;
      case "sub":
        hub.handleSub(state, env);
        return;
      case "unsub":
        hub.handleUnsub(state, env);
        return;
      case "cmd":
        void router.dispatch(state, env);
        return;
      case "ping":
        state.send({ t: "pong", id: env.id, ts: env.ts });
        return;
      case "srv.response":
        rpc.handleResponse(env);
        return;
      default:
        return;
    }
  }

  // -------- command handlers (OCP registry) -------------------------------

  function buildCommandRouter(): CommandRouter {
    const r = new CommandRouter();

    r.register("send.message", async (ctx) => {
      const sid = String(ctx.env.sessionId ?? "");
      const text = ctx.env.text;
      if (typeof text !== "string") {
        ctx.err(WireErrorCode.BadRequest, "send.message requires a string `text`");
        return;
      }
      const session = sid ? manager.getSession(sid) : undefined;
      log.info(
        `[pino] send.message sid=${sid.slice(0, 8)} session=${!!session} text="${text.slice(0, 40)}"`,
      );
      if (!session) {
        ctx.err(WireErrorCode.NoSuchSession, "no such session");
        return;
      }
      ctx.ack();
      await session.sendUserMessage(text);
    });

    r.register("cancel", async (ctx) => {
      const sid = String(ctx.env.sessionId ?? "");
      const session = sid ? manager.getSession(sid) : undefined;
      if (!session) {
        ctx.err(WireErrorCode.NoSuchSession, "no such session");
        return;
      }
      await session.adapter.cancel();
      ctx.ack();
    });

    r.register("session.spawn", async (ctx) => {
      const projectId = String(ctx.env.projectId ?? "");
      const title = ctx.env.title ? String(ctx.env.title) : undefined;
      const newSession = await manager.spawnPiSession(projectId, title);
      // wireSession is invoked via the manager's "sessionCreated" listener
      // registered above — don't call it explicitly or every event fans out
      // twice.
      broadcastSnapshots();
      ctx.ack({ sessionId: newSession.id });
    });

    // B9b: dev-only debug commands, registered only when PINO_DEV is set.
    if (process.env.PINO_DEV) registerDebugCommands(r);

    return r;
  }

  function registerDebugCommands(r: CommandRouter): void {
    r.register("debug.ask", async (ctx) => {
      ctx.ack();
      const resp = await askDevice({
        kind: "askUserQuestion",
        questions: [
          {
            header: "Test",
            question: String(ctx.env.question ?? "Pick one"),
            options: [
              { label: "Yes" },
              { label: "No" },
              { label: "Maybe", description: "If you must" },
            ],
          },
        ],
      });
      log.info(`[pino] debug.ask answered: ${JSON.stringify(resp)}`);
    });

    r.register("debug.ask-multi", async (ctx) => {
      const sid = String(ctx.env.sessionId ?? "");
      const session = sid ? manager.getSession(sid) : undefined;
      if (!session) {
        ctx.err(WireErrorCode.NoSuchSession, "no such session");
        return;
      }
      ctx.ack();
      const resp = await askDevice(
        {
          kind: "askUserQuestion",
          questions: [
            {
              header: "Language",
              question: "Which language?",
              options: [{ label: "Dart" }, { label: "TypeScript" }],
              recommended: 0,
            },
            {
              header: "Tools",
              question: "Which tools?",
              multi: true,
              options: [{ label: "Simulator" }, { label: "Server" }, { label: "Logs" }],
            },
          ],
        },
        { sessionId: sid },
      );
      log.info(`[pino] debug.ask-multi answered: ${JSON.stringify(resp)}`);
      session.adapter.emit("event", {
        ts: Date.now(),
        kind: "agent.message",
        payload: { text: JSON.stringify(resp) },
      });
    });
  }

  // -------- session fan-out + snapshots -----------------------------------

  function wireSession(session: Session) {
    session.on("event", (event) => {
      const sent = hub.fanout(session.id, event);
      log.debug(
        `[pino] session.event sid=${session.id.slice(0, 8)} kind=${event.kind} → ${sent} subscriber(s)`,
      );
      broadcastSessionsSnapshot();
    });
  }

  function sendSnapshots(client: WsClient) {
    client.send({ t: "event", id: newId("snap"), kind: "projects.snapshot", projects: manager.listProjects() });
    client.send({ t: "event", id: newId("snap"), kind: "sessions.snapshot", sessions: manager.listSessions() });
  }

  function broadcastSnapshots() {
    for (const c of clients.values()) if (c.authed) sendSnapshots(c);
  }

  function broadcastSessionsSnapshot() {
    const frame: OutgoingFrame = {
      t: "event",
      id: newId("snap"),
      kind: "sessions.snapshot",
      sessions: manager.listSessions(),
    };
    for (const c of clients.values()) if (c.authed) c.send(frame);
  }

  // -------- concrete client ------------------------------------------------

  function makeClient(ws: WebSocket, authed: boolean): ClientState {
    return {
      ws,
      authed,
      subscribed: new Set<string>(),
      send(frame: OutgoingFrame) {
        if (ws.readyState !== ws.OPEN) return;
        ws.send(encodeFrame({ v: PROTOCOL_VERSION, ...frame } as Envelope));
      },
      close(code: number, reason: string) {
        ws.close(code, reason);
      },
    };
  }
}
