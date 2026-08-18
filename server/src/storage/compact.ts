/**
 * compact.ts — remove the streamed deltas an existing log already wrote.
 *
 * `stream_digest.ts` stops new ones from being written. This is the other half:
 * a database written before that rule still holds them. One profile database
 * held 1,795,475 rows in 730 MB, 93% of them deltas.
 *
 * The compaction replays each session's log through the SAME {@link StreamDigest}
 * the live path uses, so the two rules can never drift: a stream that produced a
 * final loses its deltas, a stream that produced none becomes one aggregated row
 * at the first delta's seq, and a `tool.call.end` with no `output` is given the
 * chunks it streamed.
 *
 * Seqs are never renumbered. A client's cursor keeps its meaning, and the gaps a
 * removed delta leaves are harmless — the log was never required to be dense.
 */

import type { SessionEvent } from "../protocol.js";
import type { NewEvent } from "./event_store.js";
import { StreamDigest, isStreamDelta, TURN_END_STATUSES } from "../stream_digest.js";

/**
 * What a compaction needs from a log. Declared here, not on `EventStore`: only
 * this maintenance path removes or rewrites a row, and the append-only contract
 * is worth keeping narrow.
 */
export interface CompactableLog {
  read(sessionId: string, fromSeq?: number): SessionEvent[];
  appendAt(sessionId: string, seq: number, e: NewEvent): SessionEvent;
  /** Remove the given seqs of one session. */
  deleteEvents(sessionId: string, seqs: number[]): void;
  /** Replace one row's payload, keeping its seq, ts and kind. */
  replacePayload(sessionId: string, seq: number, payload: Record<string, unknown>): void;
  /** Every session id that has events. */
  eventSessionIds(): string[];
  /** Reclaim the space the removed rows held. */
  vacuum(): void;
}

export interface CompactOptions {
  /**
   * True when the last turn may still be streaming (the server is running). Its
   * deltas are then left alone: the live digest will write their aggregate when
   * the turn closes, and removing them now would drop text no final carries yet.
   */
  keepOpenTurn?: boolean;
}

export interface CompactResult {
  /** Delta rows removed. */
  removed: number;
  /** Aggregated rows written in their place. */
  aggregated: number;
  /** Rows whose payload gained the output its deltas carried. */
  rewritten: number;
}

/** Compact one session's log in place. */
export function compactSessionLog(
  log: CompactableLog,
  sessionId: string,
  opts: CompactOptions = {},
): CompactResult {
  const rows = log.read(sessionId, 0);
  const digest = new StreamDigest();
  const remove: number[] = [];
  const insert: Array<{ seq: number; event: NewEvent }> = [];
  const rewrite: Array<{ seq: number; payload: Record<string, unknown> }> = [];

  const closeTurn = () => {
    const { aggregates, replacedSeqs } = digest.close();
    insert.push(...aggregates);
    for (const seq of replacedSeqs) remove.push(seq);
  };

  for (const row of rows) {
    if (isStreamDelta(row.kind)) {
      digest.noteDelta(row);
      continue;
    }
    const payload = digest.noteFinal(row.kind, row.payload);
    if (payload !== row.payload) rewrite.push({ seq: row.seq, payload });
    if (
      row.kind === "session.status" &&
      TURN_END_STATUSES.has(String(row.payload.status ?? ""))
    ) {
      closeTurn();
    }
  }
  // At rest, an unclosed turn will never get its final, so its text is written
  // now rather than left as thousands of rows nothing will ever collapse.
  if (opts.keepOpenTurn !== true) closeTurn();

  for (const r of rewrite) log.replacePayload(sessionId, r.seq, r.payload);
  // Delete before inserting: an aggregate takes the seq of the first delta it
  // replaces, which is one of the rows being removed.
  if (remove.length > 0) log.deleteEvents(sessionId, remove);
  for (const a of insert) log.appendAt(sessionId, a.seq, a.event);

  return { removed: remove.length, aggregated: insert.length, rewritten: rewrite.length };
}

export interface CompactTotals extends CompactResult {
  sessions: number;
}

/**
 * Compact every session, then reclaim the space. `onSession` reports progress:
 * a 730 MB log takes long enough that silence reads as a hang.
 */
export function compactAll(
  log: CompactableLog,
  opts: CompactOptions & { onSession?: (id: string, r: CompactResult) => void } = {},
): CompactTotals {
  const totals: CompactTotals = { sessions: 0, removed: 0, aggregated: 0, rewritten: 0 };
  for (const id of log.eventSessionIds()) {
    const r = compactSessionLog(log, id, opts);
    totals.sessions++;
    totals.removed += r.removed;
    totals.aggregated += r.aggregated;
    totals.rewritten += r.rewritten;
    opts.onSession?.(id, r);
  }
  if (totals.removed > 0) log.vacuum();
  return totals;
}
