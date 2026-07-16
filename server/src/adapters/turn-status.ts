/**
 * TurnStatusTracker — the ONE "turns-in-flight + pending-approvals →
 * running/idle/awaiting-*" state machine shared by the subprocess adapters
 * (acp, codex). Both used to hand-roll it with slightly different wording,
 * which drifted into agent-specific "stuck spinner" bugs. Centralizing it kills
 * that drift.
 *
 * Semantics (union of the two prior implementations):
 *   - entering a turn emits `status: running`
 *   - leaving the last turn (with no pending approvals) emits `status: idle`
 *   - the first pending approval flips `session.status` to the given gate
 *     (awaiting-approval / awaiting-input); leaving the last one resumes
 *     `running` while a turn is still in flight
 *   - nothing is emitted once the adapter has exited
 */

export interface TurnStatusHooks {
  /** Coarse composer spinner state. */
  emitStatus: (s: "idle" | "running") => void;
  /** Fine-grained gate surfaced as a `session.status` event. */
  emitSessionStatus: (status: "awaiting-approval" | "awaiting-input") => void;
  /** The owning adapter has exited — suppress further transitions. */
  isExited: () => boolean;
}

export class TurnStatusTracker {
  /** In-flight turns, keyed by id (synthetic when the caller has none). */
  private readonly turns = new Set<string>();
  /** Pending interactive gates (approvals / input requests). */
  private approvals = 0;
  /** Monotonic source of synthetic turn keys for counter-style callers. */
  private seq = 0;

  constructor(private readonly hooks: TurnStatusHooks) {}

  /** True while any turn is in flight. */
  get hasActiveTurns(): boolean {
    return this.turns.size > 0;
  }

  /** Ids of the in-flight turns (for agents that must interrupt by id). */
  get activeTurnIds(): string[] {
    return [...this.turns];
  }

  /**
   * Begin a turn and emit `running`. Pass the agent's turn id when available
   * (codex); omit it for counter-style callers (acp) to get a synthetic key
   * back that must be handed to {@link leaveTurn}.
   */
  enterTurn(id?: string): string {
    const key = id ?? `turn-${++this.seq}`;
    this.turns.add(key);
    this.hooks.emitStatus("running");
    return key;
  }

  /** End a turn; settles to `idle` when nothing else is in flight. */
  leaveTurn(id: string): void {
    this.turns.delete(id);
    this.settleIdle();
  }

  /** Enter an interactive gate; the first one flips `session.status`. */
  enterApproval(status: "awaiting-approval" | "awaiting-input"): void {
    this.approvals += 1;
    if (this.approvals === 1) this.hooks.emitSessionStatus(status);
  }

  /** Leave the gate; resume `running` if a turn is still in flight. */
  leaveApproval(): void {
    this.approvals = Math.max(0, this.approvals - 1);
    if (this.approvals === 0 && !this.hooks.isExited() && this.turns.size > 0) {
      this.hooks.emitStatus("running");
    }
  }

  /** Emit `idle` iff fully settled (no turns, no approvals, not exited). */
  settleIdle(): void {
    if (this.turns.size === 0 && this.approvals === 0 && !this.hooks.isExited()) {
      this.hooks.emitStatus("idle");
    }
  }
}
