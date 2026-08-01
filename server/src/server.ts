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

import { createServer as createHttpsServer, type Server as HttpsServer } from "node:https";
import { WebSocketServer, type WebSocket } from "ws";
import type { Envelope, RepoDTO, GithubBudgetDTO } from "./protocol.js";
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
import { WakeCoordinator } from "./push/wake_coordinator.js";
import { NoopPushSender, type PushSender } from "./push/sender.js";
import { buildWakePayload } from "./push/payload.js";
import { registerPushCommands } from "./push/register_cmd.js";
import { register as registerSessionCommands } from "./ws/commands/session.js";
import { register as registerProjectCommands } from "./ws/commands/project.js";
import { register as registerWorktreeCommands } from "./ws/commands/worktree.js";
import { register as registerRepoCommands } from "./ws/commands/repo.js";
import { register as registerGithubCommands } from "./ws/commands/github.js";
import { register as registerDebugCommands } from "./ws/commands/debug.js";
import { register as registerDiagnosticsCommands } from "./ws/commands/diagnostics.js";
import { throttleTrailing } from "./ws/throttle.js";
import { watchWorktrees } from "./worktree_watcher.js";
import { watchPrs } from "./pr_watcher.js";
import { fetchOpenPr } from "./git.js";
import { decide } from "./github/policy.js";
import { attachMediaRoute } from "./media/route.js";
import { sharedMediaStore } from "./media/store.js";

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
  /**
   * Called when a listener fails to bind (e.g. EADDRINUSE). Defaults to
   * logging a clear one-liner and exiting — an unbound server is useless, and
   * the default unhandled-'error' crash buries the cause in a stack trace.
   */
  onListenError?: (err: NodeJS.ErrnoException, where: string) => void;
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
    onListenError = (err, where) => {
      if (err.code === "EADDRINUSE") {
        log.error(
          `[makit] cannot listen on ${where} — the port is already in use. ` +
            `Is another makit (or a dev server) still running? Stop it (\`makit stop\`, or kill the process holding the port) or pass a different --port.`,
        );
      } else {
        log.error(`[makit] failed to listen on ${where}: ${err.message}`);
      }
      process.exit(1);
    },
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

  // Assistant display media (SPEC-22): `GET/HEAD /media/<sha256>`, bearer in an
  // Authorization header. Installed on BOTH listeners — the phone fetches over
  // the external one, the `flutter run -d macos` dev loop over loopback — and
  // `request` does not interfere with the `noServer` upgrade forwarding above.
  const mediaDeps = {
    store: sharedMediaStore(),
    registry,
    trustLoopback: trustLocalhost,
  };
  attachMediaRoute(https, mediaDeps);
  if (localHttps) attachMediaRoute(localHttps, mediaDeps);

  https.on("tlsClientError", (err: Error, sock) => {
    log.warn(`[makit] TLS client error from ${sock.remoteAddress ?? "?"}: ${err.message}`);
  });
  wss.on("error", (err: Error) => {
    log.error(`[makit] wss error: ${err.message}`);
  });

  const clients = new Map<WebSocket, ClientState>();
  let reposSnapshotGeneration = 0;
  let lastEnrichedRepos: RepoDTO[] | undefined;

  // The single GitHub gateway (SPEC-32). Owned by the manager (so its
  // listRepos/enrichPrs/listOpenPrs share the one cache + quota accounting);
  // server.ts drives its budget broadcast, manual refresh/pause, and the poll
  // cadence. Refreshed ONCE at startup — construction does not self-refresh (it
  // would spawn a `gh` in tests), and until the first read the level is
  // `unknown`, which makes the policy shed unresolved counts unnecessarily.
  const gateway = manager.gateway;
  // A failed startup refresh leaves the budget at `unknown`, which makes the
  // policy shed unresolved counts and poll slowly. Log it rather than swallow:
  // a permanently failing refresh (bad token, missing `gh`) is otherwise
  // invisible and looks like the feature simply not working.
  void gateway.refresh().catch((e: unknown) => {
    log.warn(`[makit] github budget: initial rate_limit read failed: ${(e as Error).message}`);
  });
  https.on("close", () => gateway.close());

  // The current budget as a wire DTO: the tracker snapshot plus the sparkline
  // history and the exec/cache counters (spec §6.6 frozen contract).
  const budgetDto = (): GithubBudgetDTO => {
    const snapshot = gateway.budget();
    return { ...snapshot, history: gateway.history(), stats: gateway.stats() };
  };
  const broadcastBudget = (): void => {
    const frame: OutgoingFrame = { t: "event", id: newId("gh"), kind: "github.budget", budget: budgetDto() };
    for (const c of clients.values()) if (c.authed) c.send(frame);
  };
  // Last-known PR accessor for enrichPrs' retain-on-throttle (spec §6.5). Derived
  // from the same `lastEnrichedRepos` the git-only phase preserves, but keyed by
  // repo PATH + branch (not repo.id + worktree.id, which preserveLastKnownPrs
  // uses) because that is how the gateway/enrichPrs identify a lookup.
  const lastKnownPr = (repoPath: string, branch: string): RepoDTO["worktrees"][number]["pr"] => {
    if (!lastEnrichedRepos) return null;
    for (const repo of lastEnrichedRepos) {
      if (repo.path !== repoPath) continue;
      for (const worktree of repo.worktrees) if (worktree.branch === branch) return worktree.pr;
    }
    return null;
  };

  // Watch each project's git worktrees so a `git worktree add`/`remove` done
  // outside makit pushes a fresh repos.snapshot instead of waiting for the
  // next client reconnect. Kept in sync with the project set inside
  // broadcastReposSnapshot; closed when the listeners shut down.
  const worktreeWatcher = watchWorktrees(() => void broadcastReposSnapshot());
  worktreeWatcher.sync(manager.listProjects().map((p) => p.path));
  https.on("close", () => worktreeWatcher.close());

  // Poll open PRs (CI checks, state, mergeability) and re-broadcast when a
  // tracked PR actually changes (SPEC-23). GitHub has no client push API, so
  // this server-side poller is what keeps PR status fresh in the UI without a
  // manual refresh. Its tracked set is refreshed from each enriched snapshot
  // (see broadcastReposSnapshot); closed with the listeners.
  const prWatcher = watchPrs({
    // fetchOpenPr routes through the gateway: it returns the three-way PrLookup
    // so the watcher can tell a merged/closed PR (broadcast the drop) from a
    // flaky/throttled lookup (`unknown` → keep status).
    fetchPr: (repoPath, branch) => fetchOpenPr(gateway, repoPath, branch),
    onChange: () => void broadcastReposSnapshot(),
    // Drive the cadence from the degradation ladder (SPEC-32 §6.3) instead of a
    // hardcoded 5s. The old `fastMs=slowMs=5_000` was the root cause of the
    // quota burn (≥2N calls every 5s); feeding the policy's pollIntervalMs lets
    // the 5s→30s→120s→paused ladder actually take effect. `Infinity` (paused)
    // stops polling rather than busy-looping.
    intervalMs: () => decide(gateway.budget()).pollIntervalMs,
  });
  https.on("close", () => prWatcher.close());

  // Fire only on a level/throttle CHANGE (onBudgetChange already gates on that),
  // never per tick — the footer is idle most of the time. The change also pokes
  // the PR poller: the paused rung arms no timer, and `sync()` only runs on a
  // repos-snapshot broadcast, so without this a recovered quota could leave PR
  // polling dead until some unrelated event happened to fire (SPEC-32).
  //
  // Registered AFTER prWatcher exists: the callback captures it, and registering
  // earlier would leave a temporal-dead-zone hazard if a budget change ever
  // arrived synchronously.
  gateway.onBudgetChange(() => {
    broadcastBudget();
    prWatcher.poke();
  });

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
  const askDevice = rpc.askDevice.bind(rpc);
  const authGate = new AuthGate({ registry, onAuthenticated });
  const router = buildCommandRouter();

  // -------- session wiring ------------------------------------------------

  // Coalesce sessions-snapshot broadcasts: at most one per interval, with a
  // trailing flush so the final state always goes out (see wireSession).
  const throttledSessionsSnapshot = throttleTrailing(() => broadcastSessionsSnapshot(), 150);

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

  https.on("error", (err: NodeJS.ErrnoException) => onListenError(err, `${host}:${port}`));
  https.listen(port, host, () => {
    log.info(`[makit] wss listening on wss://${host}:${port}`);
  });
  if (localHttps) {
    localHttps.on("error", (err: NodeJS.ErrnoException) => onListenError(err, `127.0.0.1:${port}`));
    localHttps.listen(port, "127.0.0.1", () => {
      log.info(`[makit] wss also listening on 127.0.0.1:${port} (loopback)`);
    });
  }

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
    const deps = { manager, gateway, broadcastSnapshots, broadcastReposSnapshot, broadcastBudget, askDevice };

    registerSessionCommands(r, deps);
    registerProjectCommands(r, deps);
    registerWorktreeCommands(r, deps);
    registerRepoCommands(r, deps);
    registerGithubCommands(r, deps);

    // In-app logging: ingest client diagnostics into the server log. Always on
    // (not dev-gated) — field crash reports from iOS are a production need.
    registerDiagnosticsCommands(r);

    // SPEC-07: register the device's content-free wake push token.
    registerPushCommands(r, registry);

    // B9b: dev-only debug commands, registered only when MAKIT_DEV is set.
    if (process.env.MAKIT_DEV) registerDebugCommands(r, deps);

    return r;
  }

  // -------- session fan-out + snapshots -----------------------------------

  function wireSession(session: Session) {
    session.on("event", (event) => {
      const sent = hub.fanout(session.id, event);
      log.debug(
        `[makit] session.event sid=${session.id.slice(0, 8)} kind=${event.kind} → ${sent} subscriber(s)`,
      );
    });
    // Re-broadcast the sessions snapshot ONLY when a DTO-visible field
    // (title/status/preview/pending) changes — NOT per streaming delta
    // (SPEC-17 P2). `metaChanged` subsumes the old `titleChanged` trigger.
    // The broadcast is additionally coalesced (leading + trailing, 150ms) via
    // throttleTrailing (#66): a burst of meta changes re-encodes the full
    // sessions list for every client at most once per window.
    session.on("metaChanged", () => {
      throttledSessionsSnapshot();
    });
  }

  function sendSnapshots(client: WsClient) {
    client.send({ t: "event", id: newId("snap"), kind: "projects.snapshot", projects: manager.listProjects() });
    client.send({ t: "event", id: newId("snap"), kind: "sessions.snapshot", sessions: manager.listSessions() });
    // Include the current budget so a freshly-connected client renders the
    // footer immediately, without waiting for the next level change (spec §6.6).
    client.send({ t: "event", id: newId("gh"), kind: "github.budget", budget: budgetDto() });
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
    // Keep the fs watcher armed for the current project set, so a worktree
    // created via the CLI (outside makit) pushes a fresh snapshot promptly.
    worktreeWatcher.sync(manager.listProjects().map((p) => p.path));
    const generation = ++reposSnapshotGeneration;
    const emit = (repos: RepoDTO[]) => {
      const frame: OutgoingFrame = { t: "event", id: newId("snap"), kind: "repos.snapshot", repos };
      for (const c of clients.values()) if (c.authed) c.send(frame);
    };
    let gitOnly: RepoDTO[];
    try {
      gitOnly = await manager.listRepos({ includePrs: false });
      if (generation !== reposSnapshotGeneration) return;
      emit(preserveLastKnownPrs(gitOnly));
    } catch (e) {
      if (generation === reposSnapshotGeneration) {
        log.warn(`[makit] listRepos (git-only) failed: ${(e as Error).message}`);
      }
      return;
    }
    try {
      // Enrich the snapshot we already have — PR lookups only, no second full
      // pass of git work.
      const repos = await manager.enrichPrs(gitOnly, lastKnownPr);
      if (generation !== reposSnapshotGeneration) return;
      lastEnrichedRepos = repos;
      // Refresh the PR poller's tracked set from the authoritative snapshot so
      // it watches exactly the currently-open PRs (and re-seeds their
      // baselines, so it only fires on changes after this broadcast).
      prWatcher.sync(repos);
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
