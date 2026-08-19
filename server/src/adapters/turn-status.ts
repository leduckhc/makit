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
 *     `running` while a turn is still in flight, or settles to `idle` when the
 *     turn already ended
 *   - streamed work with nothing in flight re-opens a turn ({@link
 *     TurnStatusTracker.noteWork}), which the agent's own settle signal closes
 *   - the agent's own running signal ({@link TurnStatusTracker.noteAgentRunning})
 *     is held independently of any turn, because an agent can keep working after
 *     its prompt was answered and may stream nothing while it does
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
  /** The turn opened from streamed work, if one is open. */
  private workKey: string | null = null;
  /**
   * The agent's own "I am working" signal, held until it reports it stopped.
   *
   * Deliberately NOT a turn: pi-acp can answer makit's `session/prompt` while pi
   * works on, so the prompt turn ends first. State tied to that turn would be
   * dropped with it, and the session would report `idle` mid-work.
   */
  private agentRunning = false;

  constructor(private readonly hooks: TurnStatusHooks) {}

  /**
   * True while anything says work is in flight: a tracked turn, or the agent's
   * own running signal. ONE definition, so `settleIdle` and `leaveApproval`
   * cannot disagree about what "busy" means.
   */
  private get working(): boolean {
    return this.turns.size > 0 || this.agentRunning;
  }

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
    if (id === this.workKey) this.workKey = null;
    this.settleIdle();
  }

  /** Enter an interactive gate; the first one flips `session.status`. */
  enterApproval(status: "awaiting-approval" | "awaiting-input"): void {
    this.approvals += 1;
    if (this.approvals === 1) this.hooks.emitSessionStatus(status);
  }

  /**
   * Leave the gate; resume `running` if a turn is still in flight, else settle.
   *
   * The `else` matters: a turn can end BEFORE its gate closes (an ACP prompt
   * that resolves while `ask_user` is still waiting on the phone). Without the
   * settle, that ordering left the session pinned at `awaiting-approval` with no
   * transition left to emit — permanently "busy", which queues every later
   * message and never flushes it.
   */
  leaveApproval(): void {
    this.approvals = Math.max(0, this.approvals - 1);
    if (this.approvals > 0 || this.hooks.isExited()) return;
    if (this.working) this.hooks.emitStatus("running");
    else this.settleIdle();
  }

  /**
   * The agent streamed work: a message chunk, a thought, or a new tool call.
   *
   * An agent can keep working after its prompt was answered. pi-acp resolves
   * `session/prompt` on pi's `agent_end`, and pi emits more than one of those
   * per prompt, so a duplicate ends the turn makit tracks while the agent
   * carries on. One session then streamed 6,147 events with `status: idle`,
   * which hides the app's working shimmer and its live dot.
   *
   * The stream is the evidence, so it re-opens a turn. Called per chunk (a hot
   * path): it emits on the transition only, never per token.
   */
  noteWork(): void {
    if (this.hooks.isExited()) return;
    // The agent's own signal already holds the session running, and it alone
    // clears it — a synthetic turn here would only add a duplicate transition.
    if (this.agentRunning) return;
    if (this.turns.size > 0) return;
    this.workKey = this.enterTurn();
  }

  /**
   * The agent reported that it started working — pi-acp's `session_info_update`
   * carrying `_meta.piAcp.running: true`.
   *
   * Stronger evidence than {@link noteWork}, and the only kind that survives a
   * silent tool: a `bash` can run for minutes without streaming a byte, so there
   * is nothing to re-open a turn with. The flag is therefore sticky until
   * {@link noteAgentSettled}, and independent of the prompt turn, which pi-acp
   * routinely ends first.
   */
  noteAgentRunning(): void {
    if (this.hooks.isExited()) return;
    if (this.agentRunning) return;
    this.agentRunning = true;
    // Emit only on the transition: a turn in flight already reported `running`.
    if (this.turns.size === 0) this.hooks.emitStatus("running");
  }

  /**
   * The agent says it stopped — pi-acp's `session_info_update` carrying
   * `_meta.piAcp.running: false`. This is what closes a {@link noteWork} turn
   * and clears a {@link noteAgentRunning} flag.
   *
   * It never touches a real prompt turn: that one ends when its own promise
   * settles, and ending it here would race two sources of truth.
   */
  noteAgentSettled(): void {
    const wasRunning = this.agentRunning;
    this.agentRunning = false;
    const key = this.workKey;
    if (key !== null) {
      this.workKey = null;
      this.leaveTurn(key);
      return;
    }
    // Settle only what this signal was holding open. A settle for a turn nobody
    // opened must stay silent, or every stray report would emit a fresh `idle`.
    if (wasRunning) this.settleIdle();
  }

  /** Emit `idle` iff fully settled (no work, no approvals, not exited). */
  settleIdle(): void {
    if (!this.working && this.approvals === 0 && !this.hooks.isExited()) {
      this.hooks.emitStatus("idle");
    }
  }
}
