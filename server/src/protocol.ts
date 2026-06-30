/**
 * Wire protocol — keep in sync with `app/lib/transport/protocol.dart`.
 *
 * Single source of truth would be a shared JSON schema; for M0 we mirror by
 * hand and trust the test surface to catch drift.
 */

export const PROTOCOL_VERSION = 1;

export type MsgType =
  | "hello"
  | "hello.ack"
  | "sub"
  | "unsub"
  | "event"
  | "cmd"
  | "ack"
  | "err"
  | "presence"
  | "ping"
  | "pong"
  | "srv.request"    // server → app: ask the user something (id correlates)
  | "srv.response"; // app → server: answer to a previous srv.request

export interface Envelope {
  v: number;
  t: MsgType;
  id: string;
  [k: string]: unknown;
}

export type EventKind =
  | "user.message"
  | "agent.message"
  | "agent.thinking"
  | "tool.call.start"
  | "tool.call.delta"
  | "tool.call.end"
  | "approval.request"
  | "approval.decision"
  | "session.status"
  | "session.error"
  | "session.commands";

export interface SessionEvent {
  seq: number;
  sessionId: string;
  ts: number;
  kind: EventKind;
  payload: Record<string, unknown>;
}

export type SessionStatus =
  | "idle"
  | "running"
  | "awaiting-input"
  | "awaiting-approval"
  | "error"
  | "exited";

export type ApprovalPolicy = "yolo" | "ask-on-risky" | "ask-always";

export interface ProjectDTO {
  id: string;
  name: string;
  path: string;
  pinned: boolean;
  lastActivityAt: number;
}

export interface SessionDTO {
  id: string;
  projectId: string;
  agent: string;
  title: string;
  status: SessionStatus;
  policy: ApprovalPolicy;
  lastActivityAt: number;
  lastPreview: string;
}

let _seq = 0;
export const newId = (prefix = "id") => `${prefix}-${Date.now().toString(36)}-${(_seq++).toString(36)}`;
