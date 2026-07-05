/**
 * pino control-plane protocol (SPEC-01).
 *
 * A tiny newline-delimited JSON (NDJSON) request/response protocol spoken over
 * the local unix-domain control socket (`~/.pino/control.sock`). It lets other
 * local processes — the CLI (SPEC-02) and the desktop app (SPEC-03) — drive a
 * *running* pino without restarting it.
 *
 * **This contract is frozen**: SPEC-02/03 depend on the verb names, argument
 * shapes, and response envelopes below. Add verbs; do not repurpose existing
 * ones.
 *
 * Wire format:
 *   - Request:  `{ id, verb, args? }\n`
 *   - Response: `{ id, ok: true, data? }\n`  or  `{ id, ok: false, error }\n`
 *
 * The codec never throws: malformed input decodes to `null` so a hostile local
 * peer cannot crash the daemon by writing garbage to the socket.
 */

import type { SessionDTO } from "../protocol.js";

/** The v1 control verbs. Frozen — SPEC-02/03 depend on these. */
export const CONTROL_VERBS = [
  "status",
  "pair.mint",
  "pair.current",
  "devices.list",
  "devices.revoke",
  "sessions.list",
  "server.stop",
  "logs.tail",
] as const;

export type ControlVerb = (typeof CONTROL_VERBS)[number];

const VERB_SET: ReadonlySet<string> = new Set(CONTROL_VERBS);

export interface ControlRequest {
  id: string;
  verb: ControlVerb;
  args?: Record<string, unknown>;
}

export interface ControlOk<T = unknown> {
  id: string;
  ok: true;
  data?: T;
}

export interface ControlErr {
  id: string;
  ok: false;
  error: string;
}

export type ControlResponse<T = unknown> = ControlOk<T> | ControlErr;

// -------- per-verb data payloads (the `data` field of an ok response) -------

export interface StatusData {
  pid: number;
  uptimeMs: number;
  host: string;
  port: number;
  fingerprint: string;
  advertiseHost: string;
  pairedDevices: number;
  runningSessions: number;
  version: string;
}

/** `pair.mint` result: a fresh pair token + the pino:// URL that carries it. */
export interface PairMintData {
  url: string;
  token: string;
  expiresAt: number;
  fingerprint: string;
}

/** `pair.current` result: the active unexpired token, or `null`. */
export interface PairCurrentData {
  url: string;
  token: string;
  expiresAt: number;
}

export interface DeviceInfo {
  id: string;
  label: string;
  pairedAt: number;
  lastSeenAt: number;
  connected: boolean;
}

export interface DevicesListData {
  devices: DeviceInfo[];
}

export interface DevicesRevokeData {
  removed: boolean;
}

export interface SessionsListData {
  sessions: SessionDTO[];
}

export interface ServerStopData {
  stopping: true;
}

/** One streamed log line chunk (`logs.tail`). */
export interface LogLineData {
  line: string;
}

/** Terminal chunk for a non-follow `logs.tail`, marking the backlog complete. */
export interface LogDoneData {
  done: true;
}

/** Args for `logs.tail`. */
export interface LogsTailArgs {
  lines?: number;
  follow?: boolean;
}

// -------- codec -------------------------------------------------------------

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Serialize a request or response to a single newline-terminated wire line. */
export function encodeMessage(msg: ControlRequest | ControlResponse): string {
  return JSON.stringify(msg) + "\n";
}

/** Parse + validate a single line into a [ControlRequest], or `null`. */
export function decodeRequest(line: string): ControlRequest | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  if (typeof parsed.id !== "string") return null;
  if (typeof parsed.verb !== "string" || !VERB_SET.has(parsed.verb)) return null;
  if (parsed.args !== undefined && !isRecord(parsed.args)) return null;
  const req: ControlRequest = { id: parsed.id, verb: parsed.verb as ControlVerb };
  if (parsed.args !== undefined) req.args = parsed.args;
  return req;
}

/** Parse + validate a single line into a [ControlResponse], or `null`. */
export function decodeResponse(line: string): ControlResponse | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  if (typeof parsed.id !== "string") return null;
  if (typeof parsed.ok !== "boolean") return null;
  if (parsed.ok === false) {
    if (typeof parsed.error !== "string") return null;
    return { id: parsed.id, ok: false, error: parsed.error };
  }
  const ok: ControlOk = { id: parsed.id, ok: true };
  if (parsed.data !== undefined) ok.data = parsed.data;
  return ok;
}

/**
 * Accumulates raw socket chunks and yields complete newline-delimited lines,
 * buffering any trailing partial line until the rest arrives. Both the control
 * server and client feed socket `data` through this so a message split across
 * TCP reads is reassembled correctly.
 */
export class LineBuffer {
  private buf = "";

  push(chunk: string): string[] {
    this.buf += chunk;
    const parts = this.buf.split("\n");
    this.buf = parts.pop() ?? "";
    return parts;
  }
}
