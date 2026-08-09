/**
 * ReverseRpc — server → app request/response correlation (the "askDevice"
 * seam used by the UI-transport bridge and dev commands).
 *
 * Sends an `srv.request` up an audience ladder (SPEC-46 D13a): the session's
 * own subscribers, then the nearest ancestor's subscribers via `parentOf`,
 * then every authed client, then the wake push (`onUndeliverable`). It resolves
 * with the first *authorized* `srv.response` (D13c). Times out after
 * `timeoutMs` (default 5 min) and keeps pending / rejects per `onUndeliverable`
 * when no live client is reached.
 *
 * A prompt is never auto-answered. The resolved audience is stored on the
 * pending request so a newly-authed client is only replayed a prompt it was
 * eligible for (D13b) and a response is accepted only from a client in that
 * audience, never from an agent-scoped token (D13c).
 */

import type { Envelope, SessionOrigin } from "../protocol.js";
import type { WsClient } from "./client.js";
import { isAgentScoped } from "./principal.js";

/**
 * SPEC-46 D14 — the fields the app needs to caption a prompt for a session it
 * may never have subscribed to: the session's title, the agent/harness driving
 * it, and D10's handoff origin (`parentId`/`handoffReason`/`origin`).
 */
export interface SessionCaption {
  title: string;
  agent: string;
  parentId?: string;
  handoffReason?: string;
  origin?: SessionOrigin;
}

export interface ReverseRpcDeps {
  /** The live set of connected clients at call time. */
  clients: () => Iterable<WsClient>;
  /** Default request timeout; overridable per call. */
  defaultTimeoutMs?: number;
  /**
   * Nearest-ancestor lookup for the D13a audience ladder: the parent session
   * of `sessionId`, or `undefined` at a root (and for a missing/archived
   * ancestor). Used to climb the lineage when nobody has the spawned session
   * itself on a screen — the parent's watcher owns the consequence. Absent =
   * no lineage routing (today's session-subscribers-or-everyone behaviour).
   */
  parentOf?: (sessionId: string) => string | undefined;
  /**
   * SPEC-46 D14 — the self-describing caption for `sessionId`'s prompt: title,
   * agent/harness and handoff origin, attached to the `srv.request` so a client
   * reached at rung 3 (never subscribed, no cached session) can still caption
   * it. Absent, or returning `undefined` for an unknown/archived session, keeps
   * today's bare envelope.
   */
  sessionCaption?: (sessionId: string) => SessionCaption | undefined;
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
  /**
   * SPEC-46 D13b — the resolved audience, stored so a newly-authed client is
   * only replayed a prompt it was eligible for, and D13c can authorize the
   * response. A set of session ids: a client is eligible iff it is subscribed
   * to one of them. `undefined` means every authed client was the audience
   * (rung 3 / the wake path), so any authed non-agent client is eligible.
   */
  eligibleSessions?: Set<string>;
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
      // SPEC-46 D13b: re-send only what this client was eligible for. Without
      // this a device that was never in a prompt's audience would receive it
      // anyway on auth/`sub`.
      if (!this.isEligible(client, p)) continue;
      client.send(p.envelope);
      p.deliveredTo.add(client);
      count++;
    }
    return count;
  }

  /**
   * Route an incoming `srv.response` to its awaiting request (first wins).
   *
   * SPEC-46 D13c: the answer is authorized against the sender. It is refused
   * from an agent-scoped token (an agent approving its own tool call is the
   * supervision gap the ladder exists to close) and from any client outside
   * the prompt's stored audience. An unauthorized response is dropped, leaving
   * the request pending for a legitimate answer.
   */
  handleResponse(env: Envelope, client: WsClient): void {
    const pending = this.pending.get(env.id);
    if (pending) {
      if (isAgentScoped(client.principal)) return;
      if (!this.isEligible(client, pending)) return;
      // Clear the timeout BEFORE deleting: the promise's `.finally` looks the
      // entry up by id, so once it's gone the timer would otherwise leak until
      // it fires (up to 5 min) on every successful askDevice.
      clearTimeout(pending.timer);
      this.pending.delete(env.id);
      pending.resolve(env);
    }
  }

  /**
   * Ask a client (typically the user's phone) something and wait for an
   * authorized `srv.response`. The audience is resolved by the D13a ladder
   * (see {@link resolveAudience}); the first authorized response wins.
   */
  /**
   * SPEC-46 D13a — resolve the audience for a prompt as a ladder:
   *   1. the session's own subscribers;
   *   2. else the nearest ancestor's subscribers, climbing via `parentOf`;
   *   3. else every authed client.
   * The wake push (rung 4) is left to `onUndeliverable` when this yields no
   * live target. Returns the targets and the eligibility (session ids) stored
   * on the pending request; `eligible: undefined` means "every authed client".
   */
  private resolveAudience(sessionId?: string): {
    targets: WsClient[];
    eligible?: Set<string>;
  } {
    // Agents are excluded from every rung: a prompt is a question for a human, and
    // an agent that could see one would learn about work it cannot read (D17).
    const authed = [...this.deps.clients()].filter((c) => c.authed && !isAgentScoped(c.principal));
    if (!sessionId) return { targets: authed, eligible: undefined };

    const own = authed.filter((c) => c.subscribed.has(sessionId));
    if (own.length > 0) return { targets: own, eligible: new Set([sessionId]) };

    // Climb the lineage. `seen` terminates a forged cycle; an undefined parent
    // (root, or a missing/archived ancestor) ends the walk. Never throws.
    const seen = new Set<string>([sessionId]);
    let current = this.deps.parentOf?.(sessionId);
    while (current !== undefined && !seen.has(current)) {
      seen.add(current);
      const subs = authed.filter((c) => c.subscribed.has(current!));
      if (subs.length > 0) return { targets: subs, eligible: new Set([sessionId, current]) };
      current = this.deps.parentOf?.(current);
    }
    return { targets: authed, eligible: undefined };
  }

  /** True when `client` may receive a replay of / respond to `p` (D13b/c). */
  private isEligible(client: WsClient, p: PendingRequest): boolean {
    if (!client.authed) return false;
    // D13c refuses an agent's *answer*; D17 also refuses it the *question*. Rung 3
    // ("ask every authed client") stored no eligibility set, which read as
    // "everyone" — so a connecting agent was handed a foreign session's prompt
    // text plus D14's caption. It could never answer it; it should never see it.
    if (isAgentScoped(client.principal)) return false;
    if (p.eligibleSessions === undefined) return true;
    for (const sid of p.eligibleSessions) if (client.subscribed.has(sid)) return true;
    return false;
  }

  askDevice(
    body: Record<string, unknown>,
    opts: { sessionId?: string; timeoutMs?: number } = {},
  ): Promise<Envelope> {
    const id = `srv-${Date.now()}-${++this.reqCounter}`;
    const timeoutMs = opts.timeoutMs ?? this.deps.defaultTimeoutMs ?? DEFAULT_TIMEOUT_MS;
    const caption = opts.sessionId ? this.deps.sessionCaption?.(opts.sessionId) : undefined;
    const envelope = {
      t: "srv.request" as const,
      id,
      ...body,
      ...(opts.sessionId ? { sessionId: opts.sessionId } : {}),
      // SPEC-46 D14: make the prompt self-describing for a client reached at
      // rung 3 that never subscribed to (or has no cached copy of) the session.
      ...(caption ? { session: caption } : {}),
    } as Envelope;

    return new Promise<Envelope>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`srv.request timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      const deliveredTo = new Set<WsClient>();
      const { targets, eligible } = this.resolveAudience(opts.sessionId);
      this.pending.set(id, { resolve, timer, envelope, deliveredTo, eligibleSessions: eligible });

      let sent = 0;
      for (const c of targets) {
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
