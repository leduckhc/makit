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
  type SessionEventKind,
} from "../protocol.js";
import type { UIResponse } from "../uicall.js";

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

/**
 * Every event kind, as a `Record` so the compiler forces this list to agree with
 * the `EventKind` union: a typo is an unknown key (rejected) and a missing kind
 * is a missing required key (rejected).
 *
 * This is the same guard `HOST_ONLY_KIND_FLAGS` below uses (finding 26),
 * extended here because membership of a *host-only* kind in this set is not
 * observable through `decodeFrame` (which validates only `v`/`t`/`id`) nor
 * through `decodeSessionEvent` (which rejects the kind for being host-only
 * first). Without the compiler check, a missing entry here is silent.
 */
const EVENT_KIND_FLAGS: Record<EventKind, true> = {
  "user.message": true,
  "agent.message": true,
  "agent.message.delta": true,
  "agent.media": true,
  "agent.thinking": true,
  "agent.thinking.delta": true,
  "tool.call.start": true,
  "tool.call.delta": true,
  "tool.call.end": true,
  "session.status": true,
  "session.error": true,
  "session.commands": true,
  "session.meta": true,
  "session.action_error": true,
  "session.usage": true,
  "github.budget": true,
  "metrics.sample": true,
  "ports.snapshot": true,
  "docs.snapshot": true,
};
const EVENT_KINDS: ReadonlySet<string> = new Set(Object.keys(EVENT_KIND_FLAGS));

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isMsgType(value: unknown): value is MsgType {
  return typeof value === "string" && MSG_TYPES.has(value as MsgType);
}

function isEventKind(value: unknown): value is EventKind {
  return typeof value === "string" && EVENT_KINDS.has(value as EventKind);
}

/**
 * Host-wide broadcast kinds that must never be decoded as a session event
 * (SPEC-37 decision 5 / SPEC-32): the session log is append-only and replayed in
 * full on resume. This is the runtime half of the {@link SessionEventKind} type.
 *
 * Derived from an exhaustive `Record<Exclude<EventKind, SessionEventKind>, true>`
 * so the compiler forces this list to agree with the type-level exclusion: a
 * typo is an unknown key (rejected) and a missing kind is a missing required key
 * (rejected). The two lists cannot silently drift (finding 26).
 */
const HOST_ONLY_KIND_FLAGS: Record<Exclude<EventKind, SessionEventKind>, true> = {
  "github.budget": true,
  "metrics.sample": true,
  "ports.snapshot": true,
  "docs.snapshot": true,
};
const HOST_ONLY_KINDS: ReadonlySet<string> = new Set(Object.keys(HOST_ONLY_KIND_FLAGS));

function isSessionEventKind(value: unknown): value is SessionEventKind {
  return isEventKind(value) && !HOST_ONLY_KINDS.has(value);
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
  if (!isSessionEventKind(value.kind)) return null;
  if (!isRecord(value.payload)) return null;
  return {
    seq: value.seq,
    sessionId: value.sessionId,
    ts: value.ts,
    kind: value.kind,
    payload: value.payload,
  };
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === "string");
}

function isNumberArray(value: unknown): value is number[] {
  return Array.isArray(value) && value.every((v) => typeof v === "number");
}

/**
 * Parse + validate a device's `srv.response` envelope into a typed
 * [UIResponse], or `null`. This is the trust boundary for an untrusted client
 * reply: connectors read `resp.answers`/`resp.approved`/`resp.value` assuming a
 * concrete shape, so a malformed/hostile response must be rejected here rather
 * than blindly cast (mirrors {@link decodeSessionEvent}). The canonical fields
 * live flat at the top level alongside `v`/`t`/`id`.
 */
export function decodeUIResponse(value: unknown): UIResponse | null {
  if (!isRecord(value)) return null;
  switch (value.kind) {
    case "confirmAction":
      if (typeof value.approved !== "boolean") return null;
      return { kind: "confirmAction", approved: value.approved };
    case "askUserQuestion": {
      if (!isNumberArray(value.indices)) return null;
      if (!isStringArray(value.answers)) return null;
      if (value.answer !== undefined && typeof value.answer !== "string") return null;
      const resp: UIResponse = {
        kind: "askUserQuestion",
        indices: value.indices,
        answers: value.answers,
      };
      if (typeof value.answer === "string") resp.answer = value.answer;
      return resp;
    }
    case "input": {
      if (value.value !== undefined && typeof value.value !== "string") return null;
      if (value.cancelled !== undefined && typeof value.cancelled !== "boolean") return null;
      const resp: UIResponse = { kind: "input" };
      if (typeof value.value === "string") resp.value = value.value;
      if (typeof value.cancelled === "boolean") resp.cancelled = value.cancelled;
      return resp;
    }
    default:
      return null;
  }
}

export { PROTOCOL_VERSION };
