/**
 * SessionTokenStore — the in-memory home of per-session agent credentials
 * (SPEC-46 D3, contract C2).
 *
 * Each live session may have one agent bearer, delivered to the agent's process
 * as `MAKIT_CLI_TOKEN`. It authenticates as a **session-scoped** principal
 * (`caps: ["read","send","spawn"]`, `sessionId` set) — enough to drive its own
 * child sessions, never enough to read the whole machine (see the fanout gate
 * and the capability map).
 *
 * **Deliberately in-memory, never `devices.json`.** The device registry
 * persists to disk on every mutation, so a session token written there would
 * survive a crash as a valid credential for a session that no longer exists —
 * and would show up in `makit devices`, which D2 exists to make truthful.
 * In-memory makes D3's "rejected once its session ends" true by construction: a
 * restart has no sessions, so it has no tokens.
 *
 * The token is a 256-bit random secret; brute-forcing it is infeasible, so a
 * plain Map lookup (unlike the registry's constant-time bearer scan) is
 * acceptable here — the same reasoning the registry applies to pair tokens.
 */

import { randomBytes } from "node:crypto";
import type { Principal } from "./principal.js";

/** The caps an agent-scoped token carries (D3). */
const AGENT_CAPS = ["read", "send", "spawn"] as const;

export class SessionTokenStore {
  private readonly bySession = new Map<string, string>();
  private readonly byToken = new Map<string, string>();

  /**
   * Mint (and store) a fresh token for `sessionId`, replacing any existing one
   * so a session never has two live credentials. Returns the token to inject
   * into the agent's environment.
   */
  mint(sessionId: string): string {
    this.drop(sessionId);
    const token = randomBytes(32).toString("hex");
    this.bySession.set(sessionId, token);
    this.byToken.set(token, sessionId);
    return token;
  }

  /** Resolve a token to its session-scoped principal, or null if unknown. */
  authenticate(token: string): Principal | null {
    const sessionId = this.byToken.get(token);
    if (sessionId === undefined) return null;
    return {
      deviceId: sessionId,
      label: `agent:${sessionId}`,
      caps: [...AGENT_CAPS],
      sessionId,
    };
  }

  /** Invalidate a session's token (called when the session ends / re-attaches). */
  drop(sessionId: string): void {
    const existing = this.bySession.get(sessionId);
    if (existing === undefined) return;
    this.bySession.delete(sessionId);
    this.byToken.delete(existing);
  }
}

/**
 * The process-wide store, shared by the manager (which mints in `startOpts`)
 * and the auth gate (which authenticates). A single instance is correct: tokens
 * are meaningful only within the one running daemon that minted them.
 */
export const sessionTokens = new SessionTokenStore();
