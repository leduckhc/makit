/**
 * Shared dependencies handed to each `ws/commands/*` domain registrar
 * (SPEC-19). `server.ts` owns these closures (manager access + snapshot
 * broadcasting + the reverse-RPC askDevice); the command modules only read
 * them, keeping `server.ts` to wiring.
 */

import type {
  Envelope,
  ForwardGrantDTO,
  PortKillOrphansResult,
  PortKillResult,
  PortKillTarget,
} from "../../protocol.js";
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
   * `watchingPorts` clients and re-arm the cadence. Required (like
   * {@link onMetricsWatchersChanged}): a router built without it would ACK a
   * `ports.watch`, set the flag, and then scan nothing forever.
   */
  onPortsWatchersChanged(): void;
  /** SPEC-41: send this client the cached port snapshot, if one exists yet. */
  sendPortsSnapshot(client: WsClient): void;
  /**
   * SPEC-43: terminate the confirmed listener and report a terminal outcome. The
   * target is passed through UNCHANGED — the service re-verifies it on a fresh
   * scan and owns every refusal (D1/D3), so this seam must not pre-filter.
   * `deviceId` is carried for the audit line only (D7).
   */
  killPort(target: PortKillTarget, deviceId?: string): Promise<PortKillResult>;
  /**
   * SPEC-43 P3b: kill every current orphan (D5). The orphan set comes from the
   * server's fresh scan, never from the client, and the answer is one
   * independent outcome per endpoint.
   */
  killOrphans(deviceId?: string): Promise<PortKillOrphansResult>;
  /**
   * SPEC-44 D7: persist (or drop) the "tell me if this stops listening" flag for
   * one `(worktreePath, port)`. Synchronous: the store never throws, and the ack
   * means the write was attempted, not that a disk sync completed.
   */
  setWatchedPort(target: { worktreePath: string; port: number }, on: boolean): void;
  /**
   * SPEC-44 P4b: mint a forward grant, or explain why not. The eligibility rules
   * (D4) live server-side with the snapshot they judge, so this seam passes the
   * client's ask through untouched.
   */
  forwardPort(
    target: { worktreePath: string; port: number; browser?: boolean },
    deviceId?: string,
  ): Promise<{ grant?: ForwardGrantDTO; refusal?: string }>;
  /** SPEC-44 P4b: revoke a grant (Stop, or the sheet closing). */
  stopForward(grantId: string, deviceId?: string): void;
  /**
   * SPEC-43: run one immediate scan + broadcast, so a released endpoint
   * disappears from every watching list within the kill's round-trip instead of
   * up to one scan interval later.
   */
  rescanPorts(): void;
  /** Reverse-RPC: present a request on the device and resolve with its reply. */
  askDevice(
    body: Record<string, unknown>,
    opts?: { sessionId?: string; timeoutMs?: number },
  ): Promise<Envelope>;
}
