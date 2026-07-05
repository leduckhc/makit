/**
 * Server control backend (SPEC-01, phase 6).
 *
 * Adapts the running server's existing collaborators to the {@link ControlBackend}
 * the control server dispatches to. This is the "reuse, don't rebuild" seam:
 * it wraps `DeviceRegistry`, the `SessionManager`, the cert fingerprint, and the
 * set of currently-connected device ids — it owns no new server state except
 * the last-minted pair token (so `pair.current` can report it).
 *
 * Constructed from within `startWsServer`, which has direct in-process access
 * to all of the above, so the control socket is a genuine side channel and not
 * a second network server.
 */

import { readFileSync, existsSync, watch } from "node:fs";
import type {
  ControlBackend,
  LogTailStop,
} from "./control-server.js";
import type {
  StatusData,
  PairMintData,
  PairCurrentData,
  DevicesListData,
  SessionsListData,
  LogsTailArgs,
} from "./protocol.js";
import type { SessionDTO } from "../protocol.js";

const DEFAULT_PAIR_TTL_MS = 5 * 60 * 1000;
const DEFAULT_TAIL_LINES = 200;

/** The slice of DeviceRegistry the backend needs. */
export interface BackendRegistry {
  list(): Array<{ id: string; label: string; pairedAt: number; lastSeenAt: number }>;
  mintPairToken(ttlMs?: number): string;
  revoke(id: string): boolean;
}

/** The slice of SessionManager the backend needs. */
export interface BackendManager {
  listSessions(): SessionDTO[];
}

export interface ServerBackendDeps {
  registry: BackendRegistry;
  manager: BackendManager;
  fingerprint: string;
  host: string;
  port: number;
  advertiseHost: string;
  version: string;
  startedAt: number;
  now: () => number;
  /** Ids of devices with a live authenticated WS connection right now. */
  connectedDeviceIds: () => Set<string>;
  /** Build the pino:// pair URL for a freshly-minted token. */
  buildUrl: (token: string) => string;
  /** Trigger a graceful shutdown of the whole server process. */
  requestStop: () => void;
  logPath: string;
}

/** Adapt server internals to the control backend. */
export function createServerBackend(deps: ServerBackendDeps): ControlBackend {
  let lastMinted: PairCurrentData | null = null;

  return {
    status(): StatusData {
      const sessions = deps.manager.listSessions();
      return {
        pid: process.pid,
        uptimeMs: deps.now() - deps.startedAt,
        host: deps.host,
        port: deps.port,
        fingerprint: deps.fingerprint,
        advertiseHost: deps.advertiseHost,
        pairedDevices: deps.registry.list().length,
        runningSessions: sessions.filter((s) => s.status === "running").length,
        version: deps.version,
      };
    },

    pairMint(args): PairMintData {
      const ttlMs = args.ttlMs ?? DEFAULT_PAIR_TTL_MS;
      const token = deps.registry.mintPairToken(ttlMs);
      const url = deps.buildUrl(token);
      const expiresAt = deps.now() + ttlMs;
      lastMinted = { url, token, expiresAt };
      return { url, token, expiresAt, fingerprint: deps.fingerprint };
    },

    pairCurrent(): PairCurrentData | null {
      if (lastMinted && lastMinted.expiresAt > deps.now()) return lastMinted;
      return null;
    },

    devicesList(): DevicesListData {
      const connected = deps.connectedDeviceIds();
      return {
        devices: deps.registry.list().map((d) => ({
          id: d.id,
          label: d.label,
          pairedAt: d.pairedAt,
          lastSeenAt: d.lastSeenAt,
          connected: connected.has(d.id),
        })),
      };
    },

    devicesRevoke(args) {
      return { removed: deps.registry.revoke(args.id) };
    },

    sessionsList(): SessionsListData {
      return { sessions: deps.manager.listSessions() };
    },

    serverStop() {
      deps.requestStop();
      return { stopping: true };
    },

    logsTail(args: LogsTailArgs, emit: (line: string) => void): LogTailStop | void {
      const offset = emitBacklog(deps.logPath, args.lines ?? DEFAULT_TAIL_LINES, emit);
      if (!args.follow) return;
      return followFrom(deps.logPath, offset, emit);
    },
  };
}

/**
 * Emit the last `lines` of the log file; return the byte offset consumed.
 *
 * Reads the whole log into memory. This is acceptable for v1: `pino.log` is
 * truncated on every `start` (see service.ts) so it stays bounded to a single
 * run, and there is no consumer streaming gigabyte logs. Revisit with a bounded
 * tail-read if log rotation lands (SPEC-01 open question).
 */
function emitBacklog(path: string, lines: number, emit: (line: string) => void): number {
  if (!existsSync(path)) return 0;
  const text = readFileSync(path, "utf8");
  const all = text.split("\n");
  if (all.length > 0 && all[all.length - 1] === "") all.pop();
  for (const line of all.slice(-lines)) emit(line);
  return Buffer.byteLength(text);
}

/** Watch the log file and emit each newly-appended line until stopped. */
function followFrom(path: string, from: number, emit: (line: string) => void): LogTailStop {
  let offset = from;
  let carry = "";
  const onChange = () => {
    if (!existsSync(path)) return;
    const buf = readFileSync(path);
    if (buf.byteLength <= offset) return;
    carry += buf.subarray(offset).toString("utf8");
    offset = buf.byteLength;
    const parts = carry.split("\n");
    carry = parts.pop() ?? "";
    for (const line of parts) emit(line);
  };
  const watcher = watch(path, { persistent: false }, onChange);
  return () => watcher.close();
}
