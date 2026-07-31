/**
 * Shared dependencies handed to each `ws/commands/*` domain registrar
 * (SPEC-19). `server.ts` owns these closures (manager access + snapshot
 * broadcasting + the reverse-RPC askDevice); the command modules only read
 * them, keeping `server.ts` to wiring.
 */

import type { Envelope } from "../../protocol.js";
import type { SessionManager } from "../../manager.js";
import type { GithubGateway } from "../../github/gateway.js";

export interface CommandDeps {
  readonly manager: SessionManager;
  /** The single GitHub gateway (SPEC-32): budget, refresh, pause. */
  readonly gateway: GithubGateway;
  /** Re-send the projects + sessions snapshots to every authed client. */
  broadcastSnapshots(): void;
  /** Recompute + broadcast the repo-centric snapshot (git-only then PR-enriched). */
  broadcastReposSnapshot(): Promise<void>;
  /** Broadcast the current GitHub budget to every authed client (SPEC-32). */
  broadcastBudget(): void;
  /** Reverse-RPC: present a request on the device and resolve with its reply. */
  askDevice(
    body: Record<string, unknown>,
    opts?: { sessionId?: string; timeoutMs?: number },
  ): Promise<Envelope>;
}
