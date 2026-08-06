/**
 * Shared dependencies handed to each `ws/commands/*` domain registrar
 * (SPEC-19). `server.ts` owns these closures (manager access + snapshot
 * broadcasting + the reverse-RPC askDevice); the command modules only read
 * them, keeping `server.ts` to wiring.
 */

import type { Envelope } from "../../protocol.js";
import type { SessionManager } from "../../manager.js";
import type { GithubGateway } from "../../github/gateway.js";
import type { BudgetWatch } from "../../github/budget_watch.js";
import type { WsClient } from "../client.js";
import type { MediaStore } from "../../media/store.js";

export interface CommandDeps {
  readonly manager: SessionManager;
  /** The single GitHub gateway (SPEC-32): budget, refresh, pause. */
  readonly gateway: GithubGateway;
  /**
   * Content-addressed media store (SPEC-33) — used to resolve the attachment
   * ids on `send.message` into real descriptors. Optional and defaulted to the
   * process-wide store (mirroring `AcpAdapter`'s `opts.media`) so tests can
   * point at a temp dir without wiring a whole server.
   */
  readonly media?: MediaStore;
  /** Re-read + broadcast fast while a client has the budget panel open (SPEC-32 §6.6). */
  readonly budgetWatch: BudgetWatch<WsClient>;
  /** Re-send the projects + sessions snapshots to every authed client. */
  broadcastSnapshots(): void;
  /** Recompute + broadcast the repo-centric snapshot (git-only then PR-enriched). */
  broadcastReposSnapshot(): Promise<void>;
  /** Broadcast the current GitHub budget to every authed client (SPEC-32). */
  broadcastBudget(): void;
  /**
   * SPEC-37: recompute the collector's watcher count from the current set of
   * `watchingMetrics` clients and re-arm the cadence. Called after a
   * `metrics.watch` toggles a client's flag.
   */
  onMetricsWatchersChanged(): void;
  /** SPEC-37: send this client the metrics ring history as one `metrics.sample`. */
  sendMetricsHistory(client: WsClient): void;
  /**
   * SPEC-41: recompute the port scanner's watcher count from the current set of
   * `watchingPorts` clients and re-arm the cadence. Optional so the existing
   * `CommandDeps` test fakes need no churn; `server.ts` always supplies it.
   */
  onPortsWatchersChanged?(): void;
  /** SPEC-41: send this client the cached port snapshot, if one exists yet. */
  sendPortsSnapshot?(client: WsClient): void;
  /** Reverse-RPC: present a request on the device and resolve with its reply. */
  askDevice(
    body: Record<string, unknown>,
    opts?: { sessionId?: string; timeoutMs?: number },
  ): Promise<Envelope>;
}
