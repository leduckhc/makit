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
}

interface PendingRequest {
  resolve: (env: Envelope) => void;
  timer: NodeJS.Timeout;
}

const DEFAULT_TIMEOUT_MS = 5 * 60 * 1000; // 5 min

export class ReverseRpc {
  private readonly pending = new Map<string, PendingRequest>();
  private reqCounter = 0;

  constructor(private readonly deps: ReverseRpcDeps) {}

  /** Route an incoming `srv.response` to its awaiting request (first wins). */
  handleResponse(env: Envelope): void {
    const pending = this.pending.get(env.id);
    if (pending) {
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
    };

    return new Promise<Envelope>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`srv.request timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, { resolve, timer });

      let sent = 0;
      for (const c of this.deps.clients()) {
        if (!c.authed) continue;
        if (opts.sessionId && !c.subscribed.has(opts.sessionId)) continue;
        c.send(envelope);
        sent++;
      }
      if (sent === 0) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new Error("no subscribed clients to ask"));
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
