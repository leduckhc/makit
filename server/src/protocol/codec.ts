/**
 * Pure wire codec — validate + (de)serialize protocol frames and session
 * events with no side effects. Returns typed values on success or `null` on
 * malformed input (never throws). `server.ts` routes all incoming frames
 * through `decodeFrame` and outgoing session events through `encodeEvent`; the
 * app mirrors this in `app/lib/transport/codec.dart`. Shared JSON fixtures in
 * both test trees + the contract test lock the two ends together.
 */

import {
  PROTOCOL_VERSION,
  type Envelope,
  type EventKind,
  type MsgType,
  type SessionEvent,
} from "../protocol.js";

/** Canonical error codes carried in `err` frames. */
export enum WireErrorCode {
  Unauthorized = "unauthorized",
  NoSuchSession = "no_such_session",
  BadRequest = "bad_request",
  ProtocolVersion = "protocol_version",
  Internal = "internal",
}

const MSG_TYPES: ReadonlySet<MsgType> = new Set<MsgType>([
  "hello",
  "hello.ack",
  "sub",
  "unsub",
  "event",
  "cmd",
  "ack",
  "err",
  "presence",
  "ping",
  "pong",
  "srv.request",
  "srv.response",
]);

const EVENT_KINDS: ReadonlySet<EventKind> = new Set<EventKind>([
  "user.message",
  "agent.message",
  "agent.message.delta",
  "agent.thinking",
  "tool.call.start",
  "tool.call.delta",
  "tool.call.end",
  "session.status",
  "session.error",
  "session.commands",
  "session.meta",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isMsgType(value: unknown): value is MsgType {
  return typeof value === "string" && MSG_TYPES.has(value as MsgType);
}

function isEventKind(value: unknown): value is EventKind {
  return typeof value === "string" && EVENT_KINDS.has(value as EventKind);
}

/** Serialize an envelope to a wire frame string. */
export function encodeFrame(env: Envelope): string {
  return JSON.stringify(env);
}

/** Parse + validate a wire frame string into a typed [Envelope], or null. */
export function decodeFrame(raw: string): Envelope | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) return null;
  if (typeof parsed.v !== "number") return null;
  if (!isMsgType(parsed.t)) return null;
  if (typeof parsed.id !== "string") return null;
  return parsed as Envelope;
}

/** Serialize a session event to its wire JSON object. */
export function encodeEvent(event: SessionEvent): Record<string, unknown> {
  return {
    seq: event.seq,
    sessionId: event.sessionId,
    ts: event.ts,
    kind: event.kind,
    payload: event.payload,
  };
}

/** Parse + validate a session event object into a typed [SessionEvent], or null. */
export function decodeSessionEvent(value: unknown): SessionEvent | null {
  if (!isRecord(value)) return null;
  if (typeof value.seq !== "number") return null;
  if (typeof value.sessionId !== "string") return null;
  if (typeof value.ts !== "number") return null;
  if (!isEventKind(value.kind)) return null;
  if (!isRecord(value.payload)) return null;
  return {
    seq: value.seq,
    sessionId: value.sessionId,
    ts: value.ts,
    kind: value.kind,
    payload: value.payload,
  };
}

export { PROTOCOL_VERSION };
