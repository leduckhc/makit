/**
 * SubscriptionHub — owns per-client session subscriptions and event fan-out.
 *
 * Responsibilities:
 *   - `sub`/`unsub` handling (with replay of the session's event log on sub).
 *   - fanning a `SessionEvent` out to every authed client (auto-mirror: all
 *     connected devices see every session's events, so state stays in sync
 *     without each device having to `sub` first).
 *
 * The hub tracks the live set of clients via `register`/`unregister` so it is
 * the single authority on who receives a fan-out — no shared client map leaks
 * across collaborators.
 */

import type { Envelope, SessionEvent } from "../protocol.js";
import { newId } from "../protocol.js";
import { WireErrorCode } from "../protocol/codec.js";
import { log } from "../log.js";
import type { WsClient } from "./client.js";
import { canReadSession } from "./read_access.js";

/**
 * The slice of the session manager the hub depends on.
 *
 * `eventsSince` rather than an `events` array: a session caches only its recent
 * tail (see `Session.eventsSince`), so a first subscribe reads the older history
 * from the store instead of forcing every transcript to live in memory.
 */
export interface SubscriptionManager {
  getSession(id: string): { eventsSince(fromSeq: number): SessionEvent[] } | undefined;
}

/** A pending flush, cancellable. Injected so tests never arm a real timer. */
export interface PendingFlush {
  cancel(): void;
}

/**
 * How long events wait for company before they go out.
 *
 * 40 ms holds a burst together without being felt: the app applies a batch every
 * 50 ms anyway (see its `EventBatcher`), so a shorter window buys nothing and a
 * longer one starts to read as lag.
 */
const DEFAULT_BATCH_WINDOW_MS = 40;

/** True when this client announced `batch` in `hello` (see AuthGate). */
function acceptsBatches(client: WsClient): boolean {
  return client.acceptsEventBatches === true;
}

export interface SubscriptionHubDeps {
  manager: SubscriptionManager;
  /** Override the batching window (tests, and a future setting). */
  batchWindowMs?: number;
  /** Arm a one-shot flush. Production uses `setTimeout`. */
  schedule?: (ms: number, fn: () => void) => PendingFlush;
  /**
   * A session's parent from persisted lineage (SPEC-cli-as-client D10), for the D17 read
   * rule: a session-scoped principal reads its own session and its descendants.
   * Absent in tests that do not exercise lineage — then only the own-session case
   * can pass, which is the safe direction.
   */
  parentOf?: (sessionId: string) => string | undefined;
}

export class SubscriptionHub {
  private readonly clients = new Set<WsClient>();
  /** Events waiting for their window, per client, in arrival order. */
  private readonly pending = new Map<WsClient, SessionEvent[]>();
  /** The armed window per client, cancelled when the client leaves. */
  private readonly armed = new Map<WsClient, PendingFlush>();

  constructor(private readonly deps: SubscriptionHubDeps) {}

  /** The batching window, in ms. */
  private get windowMs(): number {
    return this.deps.batchWindowMs ?? DEFAULT_BATCH_WINDOW_MS;
  }

  private schedule(fn: () => void): PendingFlush {
    if (this.deps.schedule) return this.deps.schedule(this.windowMs, fn);
    const timer = setTimeout(fn, this.windowMs);
    timer.unref?.();
    return { cancel: () => clearTimeout(timer) };
  }

  /**
   * Send a frame that is NOT a fanned-out event, flushing this client's pending
   * events first.
   *
   * Order on one socket is a contract: `handleSub` replays a session's history
   * and then acks it, and the app treats that ack as "the replay is complete".
   * An ack that overtook the batch would make the app read replayed history as
   * live events and drop it.
   */
  sendDirect(client: WsClient, frame: Parameters<WsClient["send"]>[0]): void {
    this.flush(client);
    client.send(frame);
  }

  /** Send everything this client is holding, as one frame when it can take one. */
  flush(client: WsClient): void {
    this.armed.get(client)?.cancel();
    this.armed.delete(client);
    const events = this.pending.get(client);
    this.pending.delete(client);
    if (events === undefined || events.length === 0) return;
    if (!this.clients.has(client)) return; // gone: never write to a closed socket
    if (!acceptsBatches(client)) {
      for (const e of events) this.sendOne(client, e);
      return;
    }
    client.send({ t: "event", id: newId("evs"), kind: "session.events", events });
  }

  /** Flush every client — used when the server broadcasts to all of them. */
  flushAll(): void {
    for (const client of [...this.pending.keys()]) this.flush(client);
  }

  /** The D17 read rule for this client, resolved against persisted lineage. */
  private mayRead(client: WsClient, sessionId: string): boolean {
    return canReadSession(client.principal, sessionId, (id) => this.deps.parentOf?.(id));
  }

  register(client: WsClient): void {
    this.clients.add(client);
  }

  unregister(client: WsClient): void {
    this.clients.delete(client);
    // Drop what it was holding: the socket is going away, and a pending window
    // that fired afterwards would write to a closed one.
    this.armed.get(client)?.cancel();
    this.armed.delete(client);
    this.pending.delete(client);
  }

  handleSub(client: WsClient, env: Envelope): void {
    const sid = String(env.sessionId ?? "");
    if (!sid) {
      this.err(client, env.id, WireErrorCode.BadRequest, "missing sessionId");
      return;
    }
    const session = this.deps.manager.getSession(sid);
    if (!session) {
      this.err(client, env.id, WireErrorCode.NoSuchSession, `no such session: ${sid}`);
      return;
    }
    // D17: `sub` replays the session's whole persisted log, and it is answered
    // before the router — so the capability map never sees it and this is the only
    // place the principal can be checked. Unauthorized rather than NoSuchSession
    // would be a needless oracle; an agent has no business learning that a
    // session it cannot read exists.
    if (!this.mayRead(client, sid)) {
      this.err(client, env.id, WireErrorCode.NoSuchSession, `no such session: ${sid}`);
      return;
    }
    client.subscribed.add(sid);
    // Anything already fanned out to this client goes first: the replay frames
    // below are sent immediately, so a pending batch left behind them would
    // reach the app after history it precedes.
    this.flush(client);
    const fromSeq = typeof env.fromSeq === "number" ? env.fromSeq : 0;
    const replay = session.eventsSince(fromSeq);
    log.info(
      `[makit] sub: client subscribed to session ${sid.slice(0, 8)} (replay ${replay.length} events from seq ${fromSeq})`,
    );
    for (const e of replay) this.sendEvent(client, e);
    client.send({ t: "ack", id: env.id });
  }

  handleUnsub(client: WsClient, env: Envelope): void {
    const sid = String(env.sessionId ?? "");
    client.subscribed.delete(sid);
    client.send({ t: "ack", id: env.id });
  }

  /**
   * Fan a session event out to every authed client (auto-mirror). Subscription
   * is NOT required to receive live events — the `subscribed` set only governs
   * history replay on `sub` and prompt routing (see {@link ReverseRpc}).
   * Returns the send count.
   *
   * SPEC-cli-as-client D17 (rev 3): the auto-mirror is correct for a phone but a leak for
   * an agent — `fanout` is not a command, so the router's capability check does
   * not cover it, and a session-scoped token that merely connected would
   * otherwise receive every session's transcript. A session-scoped principal
   * therefore receives ONLY its own session's events; a `client`/no-caps
   * principal keeps today's behaviour unchanged.
   */
  fanout(sessionId: string, event: SessionEvent): number {
    let sent = 0;
    for (const c of this.clients) {
      if (!c.authed) continue;
      if (!this.mayRead(c, sessionId)) continue;
      this.queue(c, event);
      sent++;
    }
    return sent;
  }

  /** Hold [event] for [client], arming the window on the first of a burst. */
  private queue(client: WsClient, event: SessionEvent): void {
    const held = this.pending.get(client);
    if (held === undefined) {
      this.pending.set(client, [event]);
    } else {
      held.push(event);
    }
    if (!this.armed.has(client)) {
      this.armed.set(
        client,
        this.schedule(() => {
          this.armed.delete(client);
          this.flush(client);
        }),
      );
    }
  }

  /** The one-event frame, for a client that cannot take a batch. */
  private sendOne(client: WsClient, event: SessionEvent): void {
    client.send({ t: "event", id: newId("ev"), kind: "session.event", event });
  }

  private sendEvent(client: WsClient, event: SessionEvent): void {
    this.sendOne(client, event);
  }

  private err(client: WsClient, id: string, code: WireErrorCode, message: string): void {
    client.send({ t: "err", id, code, message });
  }
}
