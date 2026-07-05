/**
 * Control server (SPEC-01, phase 2).
 *
 * A `net.createServer` on the unix-domain control socket that speaks the NDJSON
 * control protocol (see `protocol.ts`). It is split into two pieces:
 *
 *   - {@link dispatchRequest} — a pure request→response(s) function driven by an
 *     injected {@link ControlBackend}. Unit-testable with a fake backend and no
 *     sockets. Never throws: a backend error becomes an `ok:false` response.
 *   - {@link createControlServer} — the socket transport that frames lines and
 *     feeds them through the dispatcher.
 *
 * ## Threat model (v1)
 *
 * The socket lives at `~/.pino/control.sock` with mode **0600** and there is NO
 * application-level auth. The security boundary is the filesystem: only the
 * owning user (and root) can open a 0600 socket, so any process able to connect
 * already runs as the user and could equally read `~/.pino/devices.json` or
 * ptrace the daemon. Adding a token here would protect nothing it doesn't
 * already control. If pino ever exposes this beyond the local user (a shared
 * host, a TCP bind), that assumption breaks and real auth must be added.
 */

import { createServer, connect, type Server, type Socket } from "node:net";
import { chmodSync, rmSync } from "node:fs";
import { log } from "../log.js";
import {
  decodeRequest,
  encodeMessage,
  LineBuffer,
  type ControlRequest,
  type ControlResponse,
  type StatusData,
  type PairMintData,
  type PairCurrentData,
  type DevicesListData,
  type DevicesRevokeData,
  type SessionsListData,
  type ServerStopData,
  type LogsTailArgs,
  LineBufferOverflowError,
} from "./protocol.js";

type Awaitable<T> = T | Promise<T>;

/** Cancels a running `logs.tail --follow` stream. */
export type LogTailStop = () => void;

/**
 * The daemon-internal operations the control server dispatches to. Injected so
 * the server is testable with a fake and the real adapter can be wired from
 * `startWsServer` with direct in-process access to registry/manager/cert.
 */
export interface ControlBackend {
  status(): Awaitable<StatusData>;
  pairMint(args: { ttlMs?: number }): Awaitable<PairMintData>;
  pairCurrent(): Awaitable<PairCurrentData | null>;
  devicesList(): Awaitable<DevicesListData>;
  devicesRevoke(args: { id: string }): Awaitable<DevicesRevokeData>;
  sessionsList(): Awaitable<SessionsListData>;
  serverStop(): Awaitable<ServerStopData>;
  /**
   * Stream log lines. Calls `emit` for each backlog line and, when
   * `args.follow`, for each subsequent line; returns a stop fn to unsubscribe.
   * For non-follow the caller sends a terminal `{ done: true }` chunk.
   */
  logsTail(args: LogsTailArgs, emit: (line: string) => void): Awaitable<LogTailStop | void>;
}

/** Sends one response frame back to the requesting client. */
type Respond = (msg: ControlResponse) => void;

/**
 * Dispatch a single request to the backend, emitting one or more responses via
 * `respond`. Returns a stop fn only for a `logs.tail --follow` stream, so the
 * transport can tear it down when the socket closes. Never throws.
 */
export async function dispatchRequest(
  req: ControlRequest,
  backend: ControlBackend,
  respond: Respond,
): Promise<LogTailStop | void> {
  const { id } = req;
  try {
    switch (req.verb) {
      case "status":
        respond({ id, ok: true, data: await backend.status() });
        return;
      case "pair.mint":
        respond({ id, ok: true, data: await backend.pairMint({ ttlMs: numArg(req, "ttlMs") }) });
        return;
      case "pair.current":
        respond({ id, ok: true, data: await backend.pairCurrent() });
        return;
      case "devices.list":
        respond({ id, ok: true, data: await backend.devicesList() });
        return;
      case "devices.revoke":
        respond({
          id,
          ok: true,
          data: await backend.devicesRevoke({ id: strArg(req, "id") }),
        });
        return;
      case "sessions.list":
        respond({ id, ok: true, data: await backend.sessionsList() });
        return;
      case "server.stop":
        respond({ id, ok: true, data: await backend.serverStop() });
        return;
      case "logs.tail": {
        const follow = req.args?.follow === true;
        const stop = await backend.logsTail(
          { lines: numArg(req, "lines"), follow },
          (line) => respond({ id, ok: true, data: { line } }),
        );
        if (!follow) {
          respond({ id, ok: true, data: { done: true } });
          return;
        }
        return stop ?? undefined;
      }
      case "logs.cancel":
        respond({ id, ok: true, data: { cancelled: false } });
        return;
    }
  } catch (e) {
    respond({ id, ok: false, error: (e as Error).message });
  }
}

// numArg/strArg intentionally coerce leniently: a mistyped or missing arg from a
// local peer degrades to the safe default (undefined / "") rather than an error.
// The verb allow-list in `decodeRequest` is the real guard; per-arg strictness
// here would add noise without adding security on a same-user socket.
function numArg(req: ControlRequest, key: string): number | undefined {
  const v = req.args?.[key];
  return typeof v === "number" ? v : undefined;
}

function strArg(req: ControlRequest, key: string): string {
  const v = req.args?.[key];
  return typeof v === "string" ? v : "";
}

export interface ControlServerOpts {
  socketPath: string;
  backend: ControlBackend;
  /**
   * Probe an existing socket file to see if a *live* daemon is answering.
   * Injected for tests; defaults to a real connect attempt. Returns true only
   * when the connect succeeds (a live peer); ECONNREFUSED/ENOENT (a stale file
   * from a crashed daemon) resolves false so we may safely unlink and rebind.
   */
  probe?: (socketPath: string) => Promise<boolean>;
}

export interface ControlServerHandle {
  server: Server;
  close(): Promise<void>;
}

/**
 * Listen on the unix control socket (mode 0600) and dispatch requests to the
/**
 * Probe a control socket: resolve true if a live daemon accepts a connection,
 * false on ECONNREFUSED/ENOENT (a stale file) or any other connect failure.
 */
function probeSocket(socketPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const sock = connect(socketPath);
    const settle = (alive: boolean) => {
      sock.removeAllListeners();
      sock.destroy();
      resolve(alive);
    };
    sock.once("connect", () => settle(true));
    sock.once("error", () => settle(false));
  });
}

/**
 * Listen on the unix control socket (mode 0600) and dispatch requests to the
 * backend. Before binding we probe any existing socket file: if a *live* daemon
 * answers we refuse to start (so a second server can't hijack the same
 * PINO_HOME); only a stale file from a crashed daemon is unlinked and rebound.
 */
export async function createControlServer(opts: ControlServerOpts): Promise<ControlServerHandle> {
  const { socketPath, backend } = opts;
  const probe = opts.probe ?? probeSocket;

  if (await probe(socketPath)) {
    throw new Error(
      `a pino daemon is already listening on ${socketPath} (refusing to start a second one)`,
    );
  }
  // No live peer answered: a leftover socket file (if any) is stale, so remove
  // it before bind() to avoid EADDRINUSE.
  rmSync(socketPath, { force: true });

  const server = createServer((sock) => handleConnection(sock, backend));
  server.on("error", (err: Error) => log.error(`[pino] control socket error: ${err.message}`));

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      server.removeListener("error", reject);
      try {
        chmodSync(socketPath, 0o600);
      } catch {
        /* best-effort: perms may fail on exotic filesystems */
      }
      resolve({
        server,
        close: () =>
          new Promise<void>((res) => {
            server.close(() => {
              rmSync(socketPath, { force: true });
              res();
            });
          }),
      });
    });
  });
}

function handleConnection(sock: Socket, backend: ControlBackend): void {
  const buf = new LineBuffer();
  const stops = new Map<string, LogTailStop>();
  const cancelled = new Set<string>();
  const pendingStops = new Set<string>();
  // Tracks whether the socket has already torn down. A `logs.tail --follow`
  // stop fn is only known after `dispatchRequest` resolves; if the socket
  // closed in that window we must invoke the stop immediately (below) rather
  // than leak the fs.watch handle by adding it to an already-drained set.
  let closed = false;
  const respond: Respond = (msg) => {
    if (sock.writable) sock.write(encodeMessage(msg));
  };

  sock.on("data", (chunk) => {
    let lines: string[];
    try {
      lines = buf.push(chunk.toString());
    } catch (e) {
      if (e instanceof LineBufferOverflowError) {
        respond({ id: "", ok: false, error: e.message });
        sock.destroy();
        return;
      }
      throw e;
    }
    for (const line of lines) {
      if (line.length === 0) continue;
      const req = decodeRequest(line);
      if (!req) {
        respond({ id: "", ok: false, error: "malformed request" });
        continue;
      }
      if (req.verb === "logs.cancel") {
        const target = typeof req.args?.id === "string" ? req.args.id : "";
        const stop = stops.get(target);
        const pending = pendingStops.has(target);
        if (stop) {
          try {
            stop();
          } catch {
            /* ignore */
          }
          stops.delete(target);
        } else if (pending) {
          cancelled.add(target);
        }
        respond({ id: req.id, ok: true, data: { cancelled: stop != null || pending } });
        continue;
      }
      if (req.verb === "logs.tail" && req.args?.follow === true) {
        pendingStops.add(req.id);
      }
      void dispatchRequest(req, backend, respond).then((stop) => {
        pendingStops.delete(req.id);
        if (!stop) return;
        if (cancelled.delete(req.id)) {
          try {
            stop();
          } catch {
            /* ignore */
          }
          return;
        }
        if (closed) {
          try {
            stop();
          } catch {
            /* ignore */
          }
          return;
        }
        stops.set(req.id, stop);
      });
    }
  });

  const cleanup = () => {
    closed = true;
    for (const stop of stops.values()) {
      try {
        stop();
      } catch {
        /* ignore */
      }
    }
    stops.clear();
    cancelled.clear();
    pendingStops.clear();
  };
  sock.on("close", cleanup);
  sock.on("error", cleanup);
}
