/**
 * SubscriptionHub — owns per-client session subscriptions and event fan-out.
 *
 * Responsibilities:
 *   - `sub`/`unsub` handling (with replay of the session's event log on sub).
 *   - fanning a `SessionEvent` out to exactly the authed clients subscribed to
 *     that session.
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

/** The slice of the session manager the hub depends on. */
export interface SubscriptionManager {
  getSession(id: string): { events: SessionEvent[] } | undefined;
}

export interface SubscriptionHubDeps {
  manager: SubscriptionManager;
}

export class SubscriptionHub {
  private readonly clients = new Set<WsClient>();

  constructor(private readonly deps: SubscriptionHubDeps) {}

  register(client: WsClient): void {
    this.clients.add(client);
  }

  unregister(client: WsClient): void {
    this.clients.delete(client);
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
    client.subscribed.add(sid);
    const fromSeq = typeof env.fromSeq === "number" ? env.fromSeq : 0;
    const replay = fromSeq > 0 ? session.events.filter((e) => e.seq > fromSeq) : session.events;
    log.info(
      `[makit] sub: client subscribed to session ${sid.slice(0, 8)} (replay ${replay.length}/${session.events.length} events from seq ${fromSeq})`,
    );
    for (const e of replay) this.sendEvent(client, e);
    client.send({ t: "ack", id: env.id });
  }

  handleUnsub(client: WsClient, env: Envelope): void {
    const sid = String(env.sessionId ?? "");
    client.subscribed.delete(sid);
    client.send({ t: "ack", id: env.id });
  }

  /** Fan a session event out to authed subscribers. Returns the send count. */
  fanout(sessionId: string, event: SessionEvent): number {
    let sent = 0;
    for (const c of this.clients) {
      if (c.authed && c.subscribed.has(sessionId)) {
        this.sendEvent(c, event);
        sent++;
      }
    }
    return sent;
  }

  private sendEvent(client: WsClient, event: SessionEvent): void {
    client.send({ t: "event", id: newId("ev"), kind: "session.event", event });
  }

  private err(client: WsClient, id: string, code: WireErrorCode, message: string): void {
    client.send({ t: "err", id, code, message });
  }
}
