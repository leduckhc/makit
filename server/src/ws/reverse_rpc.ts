/**
 * ReverseRpc — server → app request/response correlation (the "askDevice"
 * seam used by the UI-transport bridge and dev commands).
 *
 * Sends an `srv.request` to every authed client (optionally scoped to the
 * subscribers of a `sessionId`) and resolves with the first matching
 * `srv.response`. Times out after `timeoutMs` (default 5 min) and rejects if
 * there is no client to ask.
 *
 * Behaviour is preserved bit-for-bit from the original god-function so the
 * bridge and e2e path see no difference.
 */

import type { Envelope } from "../protocol.js";
import type { WsClient } from "./client.js";

export interface ReverseRpcDeps {
  /** The live set of connected clients at call time. */
  clients: () => Iterable<WsClient>;
  /** Default request timeout; overridable per call. */
  defaultTimeoutMs?: number;
  /**
   * Invoked when an `srv.request` reached NO live subscribed socket
   * (`sent === 0`). Returns the keep-pending gate: `true` keeps the request
   * pending (a real wake was dispatched, e.g. a content-free push), `false`
   * rejects immediately with "no subscribed clients to ask" (today's
   * behaviour). Token presence alone is never sufficient — see SPEC-07.
   */
  onUndeliverable?: (
    env: Envelope,
    ctx: { sessionId?: string; pendingCount: number },
  ) => boolean;
}

interface PendingRequest {
  resolve: (env: Envelope) => void;
  timer: NodeJS.Timeout;
  /** The sent envelope, retained for replay to a newly-authed client (A6). */
  envelope: Envelope;
  /** Clients this request has already been delivered to (de-dupes replay). */
  deliveredTo: Set<WsClient>;
}

const DEFAULT_TIMEOUT_MS = 5 * 60 * 1000; // 5 min

export class ReverseRpc {
  private readonly pending = new Map<string, PendingRequest>();
  private reqCounter = 0;

  constructor(private readonly deps: ReverseRpcDeps) {}

  /** Number of in-flight requests (fed to `onUndeliverable` as `pendingCount`). */
  get pendingCount(): number {
    return this.pending.size;
  }

  /**
   * Re-send every pending `srv.request` the given client has not yet received.
   * Called on auth (the `onAuthenticated` wrapper) and on `sub` so a
   * freshly-(re)connected device — e.g. one woken from force-quit with an empty
   * subscription set — gets its pending items. De-duplicated per client via
   * `deliveredTo`, so the same request is never delivered twice to one client.
   * Returns the number of requests (re)sent.
   */
  replayPendingTo(client: WsClient): number {
    let count = 0;
    for (const p of this.pending.values()) {
      if (p.deliveredTo.has(client)) continue;
      client.send(p.envelope);
      p.deliveredTo.add(client);
      count++;
    }
    return count;
  }

  /** Route an incoming `srv.response` to its awaiting request (first wins). */
  handleResponse(env: Envelope): void {
    const pending = this.pending.get(env.id);
    if (pending) {
      // Clear the timeout BEFORE deleting: the promise's `.finally` looks the
      // entry up by id, so once it's gone the timer would otherwise leak until
      // it fires (up to 5 min) on every successful askDevice.
      clearTimeout(pending.timer);
      this.pending.delete(env.id);
      pending.resolve(env);
    }
  }

  /**
   * Ask any authed client (typically the user's phone) something and wait for
   * an `srv.response`. Sends to every subscribed client of [sessionId] (or all
   * authed clients if no sessionId). The first response wins.
   */
  askDevice(
    body: Record<string, unknown>,
    opts: { sessionId?: string; timeoutMs?: number } = {},
  ): Promise<Envelope> {
    const id = `srv-${Date.now()}-${++this.reqCounter}`;
    const timeoutMs = opts.timeoutMs ?? this.deps.defaultTimeoutMs ?? DEFAULT_TIMEOUT_MS;
    const envelope = {
      t: "srv.request" as const,
      id,
      ...body,
      ...(opts.sessionId ? { sessionId: opts.sessionId } : {}),
    } as Envelope;

    return new Promise<Envelope>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`srv.request timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      const deliveredTo = new Set<WsClient>();
      this.pending.set(id, { resolve, timer, envelope, deliveredTo });

      let sent = 0;
      for (const c of this.deps.clients()) {
        if (!c.authed) continue;
        if (opts.sessionId && !c.subscribed.has(opts.sessionId)) continue;
        c.send(envelope);
        deliveredTo.add(c);
        sent++;
      }
      if (sent === 0) {
        // No live subscribed socket. Keep pending IFF a real wake was
        // dispatched (the hook returned truthy); otherwise reject now.
        const keep = this.deps.onUndeliverable?.(envelope, {
          sessionId: opts.sessionId,
          pendingCount: this.pendingCount,
        });
        if (!keep) {
          clearTimeout(timer);
          this.pending.delete(id);
          reject(new Error("no subscribed clients to ask"));
        }
      }
    }).finally(() => {
      const p = this.pending.get(id);
      if (p) {
        clearTimeout(p.timer);
        this.pending.delete(id);
      }
    });
  }
}
