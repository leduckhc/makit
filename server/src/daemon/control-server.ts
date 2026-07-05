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

import { createServer, type Server, type Socket } from "node:net";
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
    }
  } catch (e) {
    respond({ id, ok: false, error: (e as Error).message });
  }
}

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
}

export interface ControlServerHandle {
  server: Server;
  close(): Promise<void>;
}

/**
 * Listen on the unix control socket (mode 0600) and dispatch requests to the
 * backend. A stale socket file from a crashed daemon is removed first.
 */
export function createControlServer(opts: ControlServerOpts): Promise<ControlServerHandle> {
  const { socketPath, backend } = opts;
  // Remove a leftover socket from a crash so bind() doesn't EADDRINUSE.
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
  const stops = new Set<LogTailStop>();
  const respond: Respond = (msg) => {
    if (sock.writable) sock.write(encodeMessage(msg));
  };

  sock.on("data", (chunk) => {
    for (const line of buf.push(chunk.toString())) {
      if (line.length === 0) continue;
      const req = decodeRequest(line);
      if (!req) {
        respond({ id: "", ok: false, error: "malformed request" });
        continue;
      }
      void dispatchRequest(req, backend, respond).then((stop) => {
        if (stop) stops.add(stop);
      });
    }
  });

  const cleanup = () => {
    for (const stop of stops) {
      try {
        stop();
      } catch {
        /* ignore */
      }
    }
    stops.clear();
  };
  sock.on("close", cleanup);
  sock.on("error", cleanup);
}
