/**
 * stream_digest.ts — the rule that keeps streamed tokens out of the event log.
 *
 * A delta is live data, not history. The agent emits one `agent.message.delta`,
 * `agent.thinking.delta` or `tool.call.delta` per token, and the final
 * `agent.message` / `agent.thinking` / `tool.call.end` repeats the same text in
 * full. Writing both cost a profile database 1,795,475 rows and 730 MB, of which
 * 93% were deltas — each one a synchronous SQLite commit during a turn, and each
 * one held in memory for the life of the server.
 *
 * So: deltas are emitted and take a seq, but they are not persisted. When a
 * stream ends the digest says what history needs instead:
 *   - a stream that produced a final needs nothing (the final carries the text);
 *   - a stream that produced none is written as ONE aggregated event, at the seq
 *     of the first delta it replaces (a seq clients already saw, so nothing
 *     arrives twice);
 *   - a `tool.call.end` with no `output` of its own is given the joined chunks,
 *     so a tool's output can never be lost with its deltas.
 *
 * The digest is pure bookkeeping: no store, no timers, no I/O. {@link Session}
 * owns when to open, close and write.
 */

import type { SessionEvent, SessionEventKind } from "./protocol.js";
import type { NewEvent } from "./storage/event_store.js";

/** The kinds that arrive one token at a time. */
const DELTA_KINDS = new Set<string>([
  "agent.message.delta",
  "agent.thinking.delta",
  "tool.call.delta",
]);

/**
 * Statuses that end a turn, so every open stream is complete. `exited` counts:
 * a dead agent will send no final, and its text must still reach history.
 */
export const TURN_END_STATUSES: ReadonlySet<string> = new Set(["idle", "exited"]);

/** True when [kind] streams a token at a time and must stay out of the log. */
export function isStreamDelta(kind: string): boolean {
  return DELTA_KINDS.has(kind);
}

/** The payload field that identifies a stream, per delta kind. */
const STREAM_ID_FIELD: Record<string, string> = {
  "agent.message.delta": "msgId",
  "agent.thinking.delta": "thinkId",
  "tool.call.delta": "callId",
};

/** The event kind an unfinished stream is aggregated into. */
const AGGREGATE_KIND: Record<string, SessionEventKind> = {
  "agent.message.delta": "agent.message",
  "agent.thinking.delta": "agent.thinking",
  // A tool card exists from `tool.call.start`, so its text stays a delta: the
  // app appends it to that card exactly as it appends a live chunk.
  "tool.call.delta": "tool.call.delta",
};

/** The payload field an aggregate carries its text in. */
const AGGREGATE_TEXT_FIELD: Record<string, string> = {
  "agent.message.delta": "text",
  "agent.thinking.delta": "text",
  "tool.call.delta": "chunk",
};

/** The final kind that supersedes each delta kind. */
const FINAL_OF: Record<string, string> = {
  "agent.message": "agent.message.delta",
  "agent.thinking": "agent.thinking.delta",
  "tool.call.end": "tool.call.delta",
};

interface OpenStream {
  /** The delta kind, which decides how the stream is aggregated. */
  deltaKind: string;
  /** Stream id: `msgId`, `thinkId` or `callId`. */
  id: string;
  /** Seq of the first delta — the slot the aggregate takes. */
  firstSeq: number;
  /** Timestamp of the first delta. */
  firstTs: number;
  chunks: string[];
  /** Every seq this stream's deltas took, so a finished stream frees exactly its
   *  own deltas — even when streams interleave or a delta carried no chunk. */
  seqs: number[];
  /** True once a final for this stream arrived, so history needs no aggregate. */
  finalSeen: boolean;
}

/** An aggregate to write at an already-issued seq. */
export interface Aggregate {
  seq: number;
  event: NewEvent;
}

export class StreamDigest {
  /** Open streams, keyed by delta kind + stream id. */
  private readonly open = new Map<string, OpenStream>();
  /** Seqs of the deltas this turn issued, so the caller can drop them. */
  private readonly deltaSeqs = new Set<number>();

  /** True when nothing is open and nothing was issued since the last close. */
  get isEmpty(): boolean {
    return this.open.size === 0 && this.deltaSeqs.size === 0;
  }

  /**
   * Seqs of the deltas that exist ONLY in memory: the store never holds a delta,
   * and no final or aggregate has replaced these yet.
   *
   * A cache eviction must keep exactly these and may drop anything else, which
   * the store can reload. This is a live view of the digest's own set, so reading
   * it on the hot path costs nothing.
   */
  get unpersistedSeqs(): ReadonlySet<number> {
    return this.deltaSeqs;
  }

  /** Note one streamed delta. Call after the event has its seq. */
  noteDelta(event: SessionEvent): void {
    const field = STREAM_ID_FIELD[event.kind];
    if (field === undefined) return;
    this.deltaSeqs.add(event.seq);
    const id = String(event.payload[field] ?? "");
    const key = `${event.kind}\u0000${id}`;
    const chunk = typeof event.payload.chunk === "string" ? event.payload.chunk : "";
    const stream = this.open.get(key);
    if (stream === undefined) {
      this.open.set(key, {
        deltaKind: event.kind,
        id,
        firstSeq: event.seq,
        firstTs: event.ts,
        chunks: chunk === "" ? [] : [chunk],
        seqs: [event.seq],
        finalSeen: false,
      });
      return;
    }
    stream.seqs.push(event.seq);
    if (chunk !== "") stream.chunks.push(chunk);
  }

  /**
   * Note a final. Returns the payload to persist and emit: unchanged, except a
   * `tool.call.end` with no `output`, which is given the chunks it streamed.
   */
  noteFinal(kind: string, payload: Record<string, unknown>): Record<string, unknown> {
    const deltaKind = FINAL_OF[kind];
    if (deltaKind === undefined) return payload;
    const field = STREAM_ID_FIELD[deltaKind];
    const id = String(payload[field] ?? "");
    const stream = this.open.get(`${deltaKind}\u0000${id}`);
    if (stream === undefined) return payload;
    stream.finalSeen = true;
    if (kind !== "tool.call.end") return payload;
    if (typeof payload.output === "string" && payload.output !== "") return payload;
    if (stream.chunks.length === 0) return payload;
    return { ...payload, output: stream.chunks.join("") };
  }

  /**
   * Harvest deltas of streams that got a final. The final already carries the
   * text, so the deltas can be evicted from memory without writing an aggregate.
   * Call mid-turn to keep the cache bounded; `close()` will write aggregates for
   * the unfinished streams only.
   */
  harvestFinished(): Set<number> {
    const evicted = new Set<number>();
    for (const [key, stream] of this.open.entries()) {
      if (!stream.finalSeen) continue;
      // A finalized stream's deltas are redundant: its final carried the text.
      // Remove it from `open` so close() never writes an aggregate for it, and
      // return exactly its own seqs (streams interleave, so a seq range would
      // sweep up other streams' deltas or miss a delta that carried no chunk).
      this.open.delete(key);
      for (const seq of stream.seqs) {
        evicted.add(seq);
        this.deltaSeqs.delete(seq);
      }
    }
    return evicted;
  }

  /**
   * Close every open stream. Returns the aggregates history needs, oldest first,
   * and the seqs of the deltas they replace (every delta of the turn, including
   * those a final already covers).
   *
   * Called at the end of a turn: an aggregate written per delta would defeat the
   * whole purpose, and a stream is only known to be complete once the agent stops.
   */
  close(): { aggregates: Aggregate[]; replacedSeqs: Set<number> } {
    const aggregates: Aggregate[] = [];
    for (const stream of this.open.values()) {
      if (stream.finalSeen) continue;
      if (stream.chunks.length === 0) continue;
      const kind = AGGREGATE_KIND[stream.deltaKind];
      const textField = AGGREGATE_TEXT_FIELD[stream.deltaKind];
      const idField = STREAM_ID_FIELD[stream.deltaKind];
      aggregates.push({
        seq: stream.firstSeq,
        event: {
          ts: stream.firstTs,
          kind,
          payload: { [idField]: stream.id, [textField]: stream.chunks.join("") },
        },
      });
    }
    aggregates.sort((a, b) => a.seq - b.seq);
    const replacedSeqs = new Set(this.deltaSeqs);
    this.open.clear();
    this.deltaSeqs.clear();
    return { aggregates, replacedSeqs };
  }
}
