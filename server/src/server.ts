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
 * Binding:
 * The server listens on the `host:port` provided (typically Tailscale or LAN).
 * When `host` is a specific, non-loopback IP, a second loopback listener is
 * automatically added at `127.0.0.1:port` so the loopback HTTP bridge
 * and the `flutter run -d macos` dev loop keep working. The two listeners
 * share the same {@link WebSocketServer} via `noServer` upgrade forwarding,
 * so all connected clients go through the same auth gate and state.
 *
 * Localhost connections (loopback remote address) can opt out of auth via
 * `--no-auth` — useful for the `flutter run -d macos` dev loop. By default
 * even localhost is gated so behaviour matches production.
 *
 * All incoming frames are validated through the wire codec (`decodeFrame`);
 * malformed input yields an `err {code: bad_request}` and is never thrown.
 */

import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { createServer as createHttpsServer, type Server as HttpsServer } from "node:https";
import { WebSocketServer, type WebSocket } from "ws";
import type { Envelope, RepoDTO } from "./protocol.js";
import { PROTOCOL_VERSION, newId } from "./protocol.js";
import { decodeFrame, encodeFrame, WireErrorCode } from "./protocol/codec.js";
import type { SessionManager } from "./manager.js";
import type { Session } from "./session.js";
import type { DeviceRegistry } from "./pairing/registry.js";
import type { ServerCert } from "./pairing/cert.js";
import { log } from "./log.js";
import { browseDirectory } from "./project-store.js";
import type { OutgoingFrame, WsClient } from "./ws/client.js";
import { AuthGate } from "./ws/auth_gate.js";
import { SubscriptionHub } from "./ws/subscription_hub.js";
import { CommandRouter } from "./ws/command_router.js";
import { ReverseRpc } from "./ws/reverse_rpc.js";
import { WakeCoordinator } from "./push/wake_coordinator.js";
import { NoopPushSender, type PushSender } from "./push/sender.js";
import { buildWakePayload } from "./push/payload.js";
import { registerPushCommands } from "./push/register_cmd.js";

export interface ServerOpts {
  host: string;
  port: number;
  manager: SessionManager;
  cert: ServerCert;
  registry: DeviceRegistry;
  /** If true, accept loopback connections without auth. */
  trustLocalhost?: boolean;
  /**
   * Content-free wake sender (SPEC-07). Defaults to {@link NoopPushSender}
   * (wakes are no-ops → Slice-1 fallback). `index.ts` supplies an
   * `ApnsPushSender` when `~/.makit/push.json` is configured.
   */
  sender?: PushSender;
  /** Content-free payload builder (injected for testability/wiring). */
  buildWakePayload?: typeof buildWakePayload;
}

/** Concrete client: a {@link WsClient} backed by a live `ws` socket. */
interface ClientState extends WsClient {
  ws: WebSocket;
}

/** True when `host` already covers every interface (wildcard) or is purely
 * loopback. In these cases we don't need a separate local listener — binding
 * to 127.0.0.1 on top of 0.0.0.0 would EADDRINUSE, and binding twice to
 * 127.0.0.1 is redundant.
 */
function isLoopbackOrWildcard(host: string): boolean {
  return (
    host === "0.0.0.0" ||
    host === "::" ||
    host === "127.0.0.1" ||
    host === "::1" ||
    host === "::ffff:127.0.0.1" ||
    host === "localhost"
  );
}

export function startWsServer(opts: ServerOpts) {
  const {
    host,
    port,
    manager,
    cert,
    registry,
    trustLocalhost = false,
    sender = new NoopPushSender(),
    buildWakePayload: buildWakePayloadFn = buildWakePayload,
  } = opts;

  // The WSS uses noServer mode so we can forward upgrades from TWO HTTPS
  // listeners into the same connection handler:
  //   1. The external listener (host:port) — phone over Tailscale or LAN.
  //   2. A loopback listener (127.0.0.1:port) — only when `host` is a specific
  //      non-loopback IP. Keeps the loopback HTTP bridge and the
  //      `flutter run -d macos` dev loop reachable.
  // When host is `0.0.0.0` (all interfaces) or already loopback, the second
  // listener is redundant and skipped.
  const wss = new WebSocketServer({ noServer: true });
  const https: HttpsServer = createHttpsServer({ cert: cert.cert, key: cert.key });
  const needsLocalListener = !isLoopbackOrWildcard(host);
  const localHttps: HttpsServer | undefined = needsLocalListener
    ? createHttpsServer({ cert: cert.cert, key: cert.key })
    : undefined;

  const forwardUpgrade = (s: HttpsServer) => {
    s.on("upgrade", (req, socket, head) => {
      wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
    });
  };
  forwardUpgrade(https);
  if (localHttps) forwardUpgrade(localHttps);

  https.on("tlsClientError", (err: Error, sock) => {
    log.warn(`[makit] TLS client error from ${sock.remoteAddress ?? "?"}: ${err.message}`);
  });
  wss.on("error", (err: Error) => {
    log.error(`[makit] wss error: ${err.message}`);
  });

  const clients = new Map<WebSocket, ClientState>();
  let reposSnapshotGeneration = 0;
  let lastEnrichedRepos: RepoDTO[] | undefined;

  // Device ids with a live authenticated WS connection — feeds the control
  // plane's `devices.list` "connected" flag (SPEC-01) AND the wake decision
  // (SPEC-07: never wake a device that already has a live socket).
  const connectedDeviceIds = (): Set<string> => {
    const ids = new Set<string>();
    for (const c of clients.values()) if (c.authed && c.deviceId) ids.add(c.deviceId);
    return ids;
  };

  // -------- collaborators -------------------------------------------------

  const hub = new SubscriptionHub({ manager });
  // SPEC-07: the WakeCoordinator is built HERE (not in index.ts) because
  // `connectedDeviceIds` is a server.ts closure. When `askDevice` finds no live
  // subscribed socket, `onUndeliverable` wakes every paired token-bearing
  // device with no live socket and returns the keep-pending gate.
  const wakeCoordinator = new WakeCoordinator({
    registry,
    connectedDeviceIds,
    sender,
    buildWakePayload: buildWakePayloadFn,
  });
  const rpc = new ReverseRpc({
    clients: () => clients.values(),
    onUndeliverable: (env, ctx) => wakeCoordinator.wake(env, ctx),
  });
  const authGate = new AuthGate({ registry, onAuthenticated });
  const router = buildCommandRouter();

  // -------- session wiring ------------------------------------------------

  for (const s of manager.allSessions()) wireSession(s);
  // Also wire any sessions created later (e.g. via ensureDefaultSessions which
  // runs after startWsServer, or via the session.spawn cmd handler).
  manager.on("sessionCreated", (s: Session) => wireSession(s));

  // -------- connection lifecycle ------------------------------------------

  wss.on("connection", (ws, req) => {
    const remote = req.socket.remoteAddress ?? "";
    log.info(`[makit] ws connection from ${remote}`);
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
      broadcastSnapshots();
    });

    if (state.authed) {
      sendSnapshots(state);
      void broadcastReposSnapshot();
    }
  });

  https.listen(port, host, () => {
    log.info(`[makit] wss listening on wss://${host}:${port}`);
  });
  if (localHttps) {
    localHttps.listen(port, "127.0.0.1", () => {
      log.info(`[makit] wss also listening on 127.0.0.1:${port} (loopback)`);
    });
  }

  const askDevice = rpc.askDevice.bind(rpc);
  return { wss, https, localHttps, askDevice, connectedDeviceIds };

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
        // SPEC-07 A6: a freshly-(re)subscribed client may be the woken device;
        // replay any pending srv.request it hasn't seen (de-duped per client).
        rpc.replayPendingTo(state);
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
        `[makit] send.message sid=${sid.slice(0, 8)} session=${!!session} text="${text.slice(0, 40)}"`,
      );
      if (!session) {
        ctx.err(WireErrorCode.NoSuchSession, "no such session");
        return;
      }
      ctx.ack();
      // A pending (draft) session materializes its worktree + agent on the
      // first real request, which names the branch. The manager routes any
      // promotion failure through the session's own event pipeline (a real,
      // persisted, monotonic `session.error`), so the handler just checks
      // whether to proceed and refreshes the repo snapshot on success.
      if (session.pending) {
        const started = await manager.promotePendingSession(session, text);
        if (!started) return;
        broadcastSnapshots();
        void broadcastReposSnapshot();
      }
      await session.sendUserMessage(text);
    });

    // Built-in control actions (e.g. /compact, /thinking) — NOT user turns.
    // Routed to the adapter's sendAction, which maps them to the agent's SDK
    // calls (e.g. pi's set_session_name). Adapters that can't map an action
    // ignore it.
    r.register("session.action", async (ctx) => {
      const sid = String(ctx.env.sessionId ?? "");
      const action = ctx.env.action;
      if (typeof action !== "string" || !action) {
        ctx.err(WireErrorCode.BadRequest, "session.action requires a string `action`");
        return;
      }
      const session = sid ? manager.getSession(sid) : undefined;
      if (!session) {
        ctx.err(WireErrorCode.NoSuchSession, "no such session");
        return;
      }
      const args =
        ctx.env.args && typeof ctx.env.args === "object" && !Array.isArray(ctx.env.args)
          ? (ctx.env.args as Record<string, unknown>)
          : undefined;
      ctx.ack();
      // Manual rename: reflect the new title in makit immediately, then let the
      // adapter persist it (pi's set_session_name).
      if (action === "name" && typeof args?.name === "string") {
        session.setTitle(args.name);
      }
      await session.sendAction(action, args);
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

    r.register("session.kill", async (ctx) => {
      const sid = String(ctx.env.sessionId ?? "");
      try {
        await manager.killSession(sid);
      } catch {
        ctx.err(WireErrorCode.NoSuchSession, "no such session");
        return;
      }
      broadcastSnapshots();
      void broadcastReposSnapshot();
      ctx.ack();
    });

    r.register("session.spawn", async (ctx) => {
      const projectId = String(ctx.env.projectId ?? "");
      const agent = ctx.env.agent ? String(ctx.env.agent) : undefined;
      const baseBranch = ctx.env.baseBranch ? String(ctx.env.baseBranch) : undefined;
      // Optional: bind the draft to an EXISTING worktree so the first message
      // starts the agent there instead of forking a new one.
      const worktreePath = ctx.env.worktreePath ? String(ctx.env.worktreePath) : undefined;
      const branch = ctx.env.branch ? String(ctx.env.branch) : undefined;
      // New sessions are DRAFTS: the worktree + agent are deferred until the
      // first substantive message names the branch (see send.message). The
      // worktree forks off `baseBranch` (default branch when unset).
      const newSession = await manager.spawnPendingSession(projectId, agent, baseBranch, worktreePath, branch);
      // wireSession is invoked via the manager's "sessionCreated" listener
      // registered above — don't call it explicitly or every event fans out
      // twice.
      broadcastSnapshots();
      void broadcastReposSnapshot();
      ctx.ack({ sessionId: newSession.id });
    });

    r.register("repo.refresh", async (ctx) => {
      ctx.ack();
      await broadcastReposSnapshot();
    });

    r.register("agents.list", async (ctx) => {
      ctx.ack({ agents: manager.listAgents() });
    });

    r.register("session.setAgent", async (ctx) => {
      const sessionId = String(ctx.env.sessionId ?? "");
      const agent = String(ctx.env.agent ?? "");
      if (!sessionId || !agent) {
        ctx.err(WireErrorCode.BadRequest, "session.setAgent requires sessionId and agent");
        return;
      }
      try {
        manager.setPendingAgent(sessionId, agent);
      } catch (e) {
        ctx.err(WireErrorCode.BadRequest, (e as Error).message);
        return;
      }
      broadcastSnapshots();
      ctx.ack();
    });

    r.register("worktree.create", async (ctx) => {
      const projectId = String(ctx.env.projectId ?? "");
      const baseBranch = ctx.env.baseBranch ? String(ctx.env.baseBranch) : undefined;
      if (!projectId) {
        ctx.err(WireErrorCode.BadRequest, "worktree.create requires a projectId");
        return;
      }
      try {
        const wt = await manager.createWorktree(projectId, baseBranch);
        void broadcastReposSnapshot();
        ctx.ack({ projectId, path: wt.path, branch: wt.branch });
      } catch (e) {
        ctx.err(WireErrorCode.BadRequest, (e as Error).message);
      }
    });

    r.register("session.list", async (ctx) => {
      const projectId = String(ctx.env.projectId ?? "");
      if (!projectId) {
        ctx.err(WireErrorCode.BadRequest, "session.list requires a projectId");
        return;
      }
      try {
        // Omit the server-internal filesystem `path` from the wire — the app
        // attaches by piSessionId and never needs the transcript path.
        const sessions = manager.listPiSessions(projectId).map(
          ({ path: _path, ...meta }) => meta,
        );
        ctx.ack({ sessions });
      } catch (e) {
        ctx.err(WireErrorCode.BadRequest, (e as Error).message);
      }
    });

    r.register("session.attach", async (ctx) => {
      // Re-attach a rehydrated (cold) makit session to its live agent after a
      // server restart. Back-compat: legacy clients send projectId+piSessionId
      // to attach a prior on-disk pi transcript instead.
      const sessionId = String(ctx.env.sessionId ?? "");
      if (sessionId) {
        try {
          const session = await manager.reattachSession(sessionId);
          broadcastSnapshots();
          ctx.ack({ sessionId: session.id });
        } catch (e) {
          ctx.err(WireErrorCode.BadRequest, (e as Error).message);
        }
        return;
      }
      const projectId = String(ctx.env.projectId ?? "");
      const piSessionId = String(ctx.env.piSessionId ?? "");
      if (!projectId || !piSessionId) {
        ctx.err(WireErrorCode.BadRequest, "session.attach requires projectId and piSessionId");
        return;
      }
      try {
        const session = await manager.attachPiSession(projectId, piSessionId);
        broadcastSnapshots();
        ctx.ack({ sessionId: session.id });
      } catch (e) {
        ctx.err(WireErrorCode.BadRequest, (e as Error).message);
      }
    });

    r.register("project.browse", async (ctx) => {
      const raw = ctx.env.path;
      const path = typeof raw === "string" && raw.length > 0 ? raw : homedir();
      try {
        ctx.ack({ ...browseDirectory(path) });
      } catch (e) {
        ctx.err(WireErrorCode.BadRequest, (e as Error).message);
      }
    });

    r.register("project.add", async (ctx) => {
      const path = typeof ctx.env.path === "string" ? ctx.env.path : "";
      if (!path) {
        ctx.err(WireErrorCode.BadRequest, "project.add requires a string `path`");
        return;
      }
      const full = resolve(path);
      if (!existsSync(full) || !statSync(full).isDirectory()) {
        ctx.err(WireErrorCode.BadRequest, `not a directory: ${full}`);
        return;
      }
      const project = manager.addProject(full);
      broadcastSnapshots();
      await broadcastReposSnapshot();
      ctx.ack({ projectId: project.id });
    });

    r.register("project.remove", async (ctx) => {
      const projectId = typeof ctx.env.projectId === "string" ? ctx.env.projectId : "";
      if (!projectId) {
        ctx.err(WireErrorCode.BadRequest, "project.remove requires a string `projectId`");
        return;
      }
      try {
        manager.removeProject(projectId);
      } catch (e) {
        ctx.err(WireErrorCode.BadRequest, (e as Error).message);
        return;
      }
      broadcastSnapshots();
      await broadcastReposSnapshot();
      ctx.ack({});
    });

    // SPEC-07: register the device's content-free wake push token.
    registerPushCommands(r, registry);

    // B9b: dev-only debug commands, registered only when MAKIT_DEV is set.
    if (process.env.MAKIT_DEV) registerDebugCommands(r);

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
      log.info(`[makit] debug.ask answered: ${JSON.stringify(resp)}`);
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
      log.info(`[makit] debug.ask-multi answered: ${JSON.stringify(resp)}`);
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
        `[makit] session.event sid=${session.id.slice(0, 8)} kind=${event.kind} → ${sent} subscriber(s)`,
      );
      broadcastSessionsSnapshot();
    });
    session.on("titleChanged", () => {
      broadcastSessionsSnapshot();
    });
  }

  function sendSnapshots(client: WsClient) {
    client.send({ t: "event", id: newId("snap"), kind: "projects.snapshot", projects: manager.listProjects() });
    client.send({ t: "event", id: newId("snap"), kind: "sessions.snapshot", sessions: manager.listSessions() });
  }

  /**
   * Compute + broadcast the repo-centric snapshot (branches, worktrees, diff
   * stats, PRs). Fired on connect, spawn, session start, kill, and explicit
   * `repo.refresh` — never per event.
   *
   * Two phases so the +/- diff numbers (pure local git, instant) never wait on
   * the open-PR lookup (`gh`, network, seconds): first broadcast the git-only
   * snapshot, then re-broadcast with PRs enriched.
   */
  function preserveLastKnownPrs(repos: RepoDTO[]): RepoDTO[] {
    if (!lastEnrichedRepos) return repos;
    const prs = new Map<string, RepoDTO["worktrees"][number]["pr"]>();
    for (const repo of lastEnrichedRepos) {
      for (const worktree of repo.worktrees) prs.set(`${repo.id}\0${worktree.id}`, worktree.pr);
    }
    return repos.map((repo) => ({
      ...repo,
      worktrees: repo.worktrees.map((worktree) => {
        const key = `${repo.id}\0${worktree.id}`;
        return prs.has(key) ? { ...worktree, pr: prs.get(key)! } : worktree;
      }),
    }));
  }

  async function broadcastReposSnapshot() {
    const generation = ++reposSnapshotGeneration;
    const emit = (repos: RepoDTO[]) => {
      const frame: OutgoingFrame = { t: "event", id: newId("snap"), kind: "repos.snapshot", repos };
      for (const c of clients.values()) if (c.authed) c.send(frame);
    };
    try {
      const repos = await manager.listRepos({ includePrs: false });
      if (generation !== reposSnapshotGeneration) return;
      emit(preserveLastKnownPrs(repos));
    } catch (e) {
      if (generation === reposSnapshotGeneration) {
        log.warn(`[makit] listRepos (git-only) failed: ${(e as Error).message}`);
      }
      return;
    }
    try {
      const repos = await manager.listRepos({ includePrs: true });
      if (generation !== reposSnapshotGeneration) return;
      lastEnrichedRepos = repos;
      emit(repos);
    } catch (e) {
      if (generation === reposSnapshotGeneration) {
        log.warn(`[makit] listRepos (PR enrich) failed: ${(e as Error).message}`);
      }
    }
  }

  // SPEC-07 A6: replay lives ONLY here (on auth) and in the `sub` handler —
  // never in `sendSnapshots`, which `broadcastSnapshots` fires on every session
  // event and would otherwise re-fire replay constantly. A force-quit-then-woken
  // app has an empty subscription set, so replay-on-`sub` alone is insufficient;
  // replaying on auth delivers pending items regardless of subscription.
  function onAuthenticated(client: WsClient) {
    sendSnapshots(client);
    void broadcastReposSnapshot();
    rpc.replayPendingTo(client);
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
