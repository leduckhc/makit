import { EventEmitter } from "node:events";
import type { AdapterEvent, AgentAdapter, SessionCapabilities, SpawnOpts, UserInput } from "./adapter.js";
import { sharedMediaStore } from "../media/store.js";
import { prepareTurnOrFail } from "../media/attach.js";
import type { SessionConfigOption } from "../protocol.js";
import type { UIResponse } from "../uicall.js";
import { TurnStatusTracker } from "./turn-status.js";

export interface StubAdapterOptions {
  askUser?: (body: Record<string, unknown>) => Promise<UIResponse>;
}

const echoDelayMs = 50;

/// Deterministic markdown reply exercised by the app's markdown_render E2E:
/// heading, bold, a link, and a fenced dart code block (copy + highlight).
const MARKDOWN_SAMPLE = [
  "# Markdown demo",
  "",
  "Some **bold** text and a [link](https://flutter.dev).",
  "",
  "```dart",
  "void main() {}",
  "```",
].join("\n");

/// Deterministic in-process adapter used by `e2e-server.ts --mode=stub`.
/// No subprocess, no LLM, no flakiness — scripted replies based on user text:
///   - "ASK_MULTI"     → multi-question / multi-select askUserQuestion round-trip
///   - "ASK_QUESTION"  → single-question askUserQuestion round-trip
///   - "MARKDOWN"      → a markdown reply (heading, link, fenced dart code block)
///   - "AWAIT_APPROVAL"→ raise a real `confirmAction` prompt and park the turn on
///                       the tool-permission gate until it is answered
///   - "AWAIT_INPUT"   → raise a real `input` prompt and park on the elicitation
///                       gate until it is answered
///   - "FAIL_TURN"     → a terminal `session.error`, then settle IDLE (not "error")
///   - anything else   → `echo: <text>` after 50ms
export class StubAdapter extends EventEmitter implements AgentAdapter {
  readonly agent = "stub";

  /** Resume-capable so keyless e2e can exercise the server-restart resume path
   *  (SPEC-29): the manager persists {@link agentSessionId} and re-attaches by it. */
  readonly capabilities: SessionCapabilities = { resume: true, load: false, list: true, delete: true, fork: false, archive: false };
  agentSessionId?: string;

  private sessionId = "";
  /** Session cwd — attachments are materialised here, as on a real adapter. */
  private workspaceRoot = "";
  private askUser?: (body: Record<string, unknown>) => Promise<UIResponse>;
  /**
   * The pending completion of a **deferred turn** — SLOW's late reply or
   * FAIL_TURN's error — cleared by `cancel()`/`kill()` so a cancelled or dead
   * adapter never emits afterwards. `turnKey` is present only when the deferral
   * entered a *tracked* turn (FAIL_TURN), so cancelling can leave that turn
   * instead of stranding the tracker in `running` forever.
   */
  private pendingTurn?: { handle: ReturnType<typeof setTimeout>; turnKey?: string };

  /** Turns taken so far — drives the deterministic usage ramp (SPEC-37). */
  private turnCount = 0;

  /**
   * SPEC-46 (T15): the same turns/gates state machine the real subprocess
   * adapters use, so a parked stub turn is indistinguishable on the wire from a
   * parked codex or pi turn. Hand-rolling it here is what the tracker exists to
   * prevent: the coarse `status` channel only carries `"idle" | "running"`, so
   * `awaiting-approval` is a `session.status` EVENT, and two spellings of that
   * is precisely the drift that produced stuck-spinner bugs in acp/codex.
   */
  private readonly turns = new TurnStatusTracker({
    emitStatus: (s) => this.emit("status", s),
    emitSessionStatus: (status) =>
      this.emitEvent({ ts: Date.now(), kind: "session.status", payload: { status } }),
    isExited: () => this.exited,
  });

  /** True once killed — suppresses any further transition (tracker contract). */
  private exited = false;

  /** Key of the turn parked on a gate, so cancel can release it. */
  private gatedTurn?: string;

  constructor(options: StubAdapterOptions = {}) {
    super();
    this.askUser = options.askUser;
  }

  async start(opts: SpawnOpts): Promise<void> {
    this.sessionId = opts.sessionId ?? "";
    this.workspaceRoot = opts.cwd;
    // Echo back a native id so the manager can persist + resume it. On resume,
    // reuse the id makit hands us so identity is stable across a restart.
    this.agentSessionId = opts.resumeAgentSessionId ?? `stub-${this.sessionId || Date.now()}`;
    this.emit("status", "idle");
    this.emitMeta();
    this.emitEvent({
      ts: Date.now(),
      kind: "session.commands",
      payload: {
        commands: [
          {
            name: "ask",
            description: "Debug: ask one question",
            source: "extension",
          },
        ],
      },
    });
  }

  async send(input: UserInput): Promise<void> {
    // SPEC-33: the stub takes the SAME delivery path as the real adapters
    // (materialise into the worktree, name the file in the prompt, echo
    // descriptors). Without this the keyless e2e loop would "pass" while
    // exercising nothing, and the dev/demo loop would silently drop images.
    const turn = prepareTurnOrFail(sharedMediaStore(), input, this.workspaceRoot, (e) =>
      this.emitEvent(e),
    );
    if (!turn) return;
    this.emitEvent({ ts: Date.now(), kind: "user.message", payload: turn.echo });
    // SPEC-37: usage must ramp on the SAME path the real adapters take, or the
    // keyless e2e loop would render an indicator that no code ever fed. Shaped
    // like codex's report: context tracks the latest request, totals accumulate.
    this.emitUsage();
    // Replies are scripted off the user's own text; the file references are for
    // the (imaginary) agent, so keep the trigger words unaffected by them.
    const prompt = turn.promptText;

    if (input.text.includes("ASK_MULTI")) {
      await this.askMultiQuestion();
      return;
    }
    if (input.text.includes("ASK_QUESTION")) {
      await this.askSingleQuestion();
      return;
    }
    if (input.text.includes("MARKDOWN")) {
      setTimeout(() => {
        this.emitEvent({
          ts: Date.now(),
          kind: "agent.message",
          payload: { text: MARKDOWN_SAMPLE },
        });
      }, echoDelayMs);
      return;
    }

    // SPEC-46 (T15) — the two states `makit wait` must be able to observe, and
    // the one it must NOT confuse with a status. Placed before SLOW/STREAM so a
    // prompt naming a gate is never swallowed by another trigger.
    //
    // AWAIT_APPROVAL / AWAIT_INPUT: a turn genuinely in flight, then blocked on
    // the user. The gate never clears itself — `makit wait --for approval` exiting
    // 10 is only meaningful if it persists — but it IS released by an answer,
    // because production adapters go `awaiting-*` *because* they asked something.
    // Parking the status without asking made the flow the CLI exists for
    // (`run` → exit 10 → `makit approve` → the turn finishes) impossible to
    // exercise, and made `approve` look broken against a session that plainly
    // reported `[awaiting-approval]`.
    if (prompt.includes("AWAIT_APPROVAL") || prompt.includes("AWAIT_INPUT")) {
      const approval = prompt.includes("AWAIT_APPROVAL");
      const gate = approval ? "awaiting-approval" : "awaiting-input";
      this.gatedTurn = this.turns.enterTurn();
      this.turns.enterApproval(gate);
      // No bridge (a unit test constructing the adapter bare) → the gate simply
      // persists, which is the older behaviour and still what those tests assert.
      if (!this.askUser) return;
      // `sessionId` is not decoration: the server strips it to attribute the
      // prompt, which is what D13's ladder routes on and what `makit approve <id>`
      // matches. Without it the question is unroutable and unanswerable.
      const body: Record<string, unknown> = approval
        ? {
            sessionId: this.sessionId,
            kind: "confirmAction",
            title: "Run `rm -rf build`?",
            message: "the stub was asked to request approval",
            action: "bash",
            preview: "rm -rf build",
          }
        : { sessionId: this.sessionId, kind: "input", title: "What should the stub use?", prefill: "" };
      void this.askUser(body)
        .then(() => this.releaseGate())
        .catch(() => this.releaseGate());
      return;
    }

    // FAIL_TURN: a turn that fails. The status settles **idle**, not "error" —
    // nothing in makit ever emits `status: "error"` (the real adapters emit
    // `session.error` and then settle), which is exactly why `makit wait` keys
    // its failure exit code off the EVENT. Encoded here so the stub cannot
    // quietly acquire an "error" status and invalidate that design.
    if (prompt.includes("FAIL_TURN")) {
      const key = this.turns.enterTurn();
      const handle = setTimeout(() => {
        this.pendingTurn = undefined;
        this.emitEvent({
          ts: Date.now(),
          kind: "session.error",
          payload: { message: `FAIL_TURN: the stub was asked to fail this turn (${prompt})` },
        });
        this.turns.leaveTurn(key);
      }, echoDelayMs);
      // Tracked, so `kill()` cannot let a terminal error land after the exit and
      // `cancel()` cannot leave the turn wedged running.
      this.pendingTurn = { handle, turnKey: key };
      return;
    }

    // "SLOW [ms]" → a turn that OUTLIVES a keystroke: running now, reply after
    // `ms` (default 12s), then idle. The queue (SPEC-35/36) only exists while the
    // agent is busy, so without this the keyless loop — and the demo — has no
    // window in which a message can be queued, edited or reordered at all.
    if (prompt.includes("SLOW")) {
      const ms = Number(/SLOW\s+(\d+)/.exec(prompt)?.[1] ?? 12_000);
      this.emit("status", "running");
      const handle = setTimeout(() => {
        this.pendingTurn = undefined;
        this.emitEvent({
          ts: Date.now(),
          kind: "agent.message",
          payload: { text: `done after ${ms}ms: ${prompt}` },
        });
        this.emit("status", "idle");
      }, ms);
      this.pendingTurn = { handle };
      return;
    }

    // "STREAM" → emit running status, a few agent.message.delta tokens, then
    // the final authoritative agent.message, then idle. Exercises live token
    // streaming + the working indicator end-to-end.
    if (input.text.includes("STREAM")) {
      this.emit("status", "running");
      const msgId = `am-${Date.now()}`;
      const chunks = ["Stream", "ing ", "reply"];
      let i = 0;
      const tick = () => {
        if (i < chunks.length) {
          this.emitEvent({
            ts: Date.now(),
            kind: "agent.message.delta",
            payload: { msgId, chunk: chunks[i] },
          });
          i += 1;
          setTimeout(tick, 30);
        } else {
          this.emitEvent({
            ts: Date.now(),
            kind: "agent.message",
            payload: { msgId, text: "Streaming reply" },
          });
          this.emit("status", "idle");
        }
      };
      setTimeout(tick, echoDelayMs);
      return;
    }
    // "THINK" → emit a reasoning trace (folded thinking card) then a reply.
    if (input.text.includes("THINK")) {
      this.emitEvent({
        ts: Date.now(),
        kind: "agent.thinking",
        payload: {
          text: "Let me reason about this step by step before answering.",
        },
      });
      this.emitEvent({
        ts: Date.now(),
        kind: "agent.message",
        payload: { text: "Done reasoning." },
      });
      return;
    }


    // A turn, not just a reply: running → echo → idle, like every real adapter.
    // Without the idle the SESSION never gets the transition that flushes the
    // next queued message, so a queue of two stalled after the first — visible
    // only in the live loop (the unit tests drive `idle` by hand).
    this.emit("status", "running");
    setTimeout(() => {
      this.emitEvent({
        ts: Date.now(),
        kind: "agent.message",
        payload: { text: `echo: ${prompt}` },
      });
      this.emit("status", "idle");
    }, echoDelayMs);
  }

  /** No mid-turn injection (SPEC-35): the session layer queues instead. */
  async steer(_input: UserInput): Promise<boolean> {
    return false;
  }

  async cancel(): Promise<void> {
    const settled = this.clearPendingTurn();
    if (this.releaseGate()) return;
    // A tracked deferral already settled via `leaveTurn`; an untracked one (SLOW
    // drives the status directly) still needs the idle.
    if (!settled) this.emit("status", "idle");
  }

  /**
   * Cancel a deferred turn completion. Returns true when doing so already
   * settled the status (a tracked turn was left), false otherwise.
   */
  private clearPendingTurn(): boolean {
    const pending = this.pendingTurn;
    if (pending === undefined) return false;
    this.pendingTurn = undefined;
    clearTimeout(pending.handle);
    if (pending.turnKey === undefined) return false;
    this.turns.leaveTurn(pending.turnKey);
    return true;
  }

  /**
   * Release a parked gate (SPEC-46 T15) without emitting the intermediate
   * "running" that `leaveApproval` would otherwise produce: drop the TURN first
   * so the tracker has nothing to resume to, then the gate, then settle. A cancel
   * that left the gate counted would wedge the session for good — `settleIdle`
   * could never fire again, so every later turn would look stuck.
   *
   * Returns whether there was a gate to release. Called both by `cancel` and when
   * the user *answers* the prompt that raised the gate.
   */
  private releaseGate(): boolean {
    if (this.gatedTurn === undefined) return false;
    this.turns.leaveTurn(this.gatedTurn);
    this.gatedTurn = undefined;
    this.turns.leaveApproval();
    this.turns.settleIdle();
    return true;
  }

  /**
   * Deterministic `session.usage` ramp (SPEC-37): a fixed per-turn context cost
   * on top of a fixed baseline (the real baseline being system prompt + tool
   * definitions), against a plausible window. Totals and cost accumulate.
   */
  private emitUsage(): void {
    this.turnCount += 1;
    const baseline = 19_000;
    const perTurn = 1_200;
    const contextTokens = baseline + perTurn * this.turnCount;
    const input = contextTokens * this.turnCount;
    const output = 5 * this.turnCount;
    this.emitEvent({
      ts: Date.now(),
      kind: "session.usage",
      payload: {
        contextTokens,
        contextWindow: 258_400,
        totals: {
          total: input + output,
          input,
          cachedInput: this.turnCount > 1 ? baseline : 0,
          cacheWrite: 0,
          output,
          reasoning: 0,
        },
        cost: { amount: Number((0.021 * this.turnCount).toFixed(3)), currency: "USD" },
        measuredAt: Date.now(),
      },
    });
  }

  /** SPEC-26: a tiny deterministic config catalog so keyless e2e runs can
   *  exercise the unified `configOptions` render + set round-trip. */
  private configOptions: Array<SessionConfigOption> = [
    // Mixed boolean + string currentValue types require explicit array type annotation
    {
      id: "model",
      name: "Model",
      category: "model",
      type: "select",
      currentValue: "stub-normal",
      options: [
        { value: "stub-normal", name: "Stub Normal" },
        { value: "stub-fast", name: "Stub Fast" },
      ],
    },
    {
      id: "thought_level",
      name: "Thinking",
      category: "thought_level",
      type: "select",
      currentValue: "low",
      options: [
        { value: "off", name: "Off" },
        { value: "low", name: "Low" },
        { value: "high", name: "High" },
      ],
    },
    {
      id: "context",
      name: "Context",
      category: "model_config",
      type: "select",
      currentValue: "256k",
      options: [
        { value: "128k", name: "128k" },
        { value: "256k", name: "256k" },
        { value: "1m", name: "1M" },
      ],
    },
    {
      id: "fast",
      name: "Fast",
      category: "model_config",
      type: "boolean",
      currentValue: true,
    },
  ];

  async sendAction(action: string, args?: Record<string, unknown>): Promise<void> {
    if (action !== "configOption") return;
    const id = args?.id;
    const value = args?.value;
    const target = this.configOptions.find((o) => o.id === id);
    if (!target) return;
    // Accept booleans for boolean options (e.g. `fast`), strings for selects.
    const ok =
      target.type === "boolean" ? typeof value === "boolean" : typeof value === "string";
    if (!ok) return;
    const next = value as string | boolean;
    this.configOptions = this.configOptions.map((o) =>
      o.id === id ? { ...o, currentValue: next } : o,
    );
    this.emitMeta();
  }

  private emitMeta(): void {
    this.emitEvent({
      ts: Date.now(),
      kind: "session.meta",
      payload: { configOptions: this.configOptions },
    });
  }

  async kill(): Promise<void> {
    // Exited FIRST: `settleIdle` is suppressed once `isExited()`, so cancelling
    // the deferred turn below cannot emit a status for an adapter already gone.
    this.exited = true;
    this.clearPendingTurn();
    this.emit("exit", null);
  }

  private async askSingleQuestion(): Promise<void> {
    if (!this.askUser) return this.emitBridgeMissing();
    try {
      const response = await this.askUser({
        sessionId: this.sessionId,
        kind: "askUserQuestion",
        questions: [
          {
            header: "Stub",
            question: "Pick a greeting",
            options: [{ label: "Hello" }, { label: "Hola" }],
            recommended: 0,
          },
        ],
      });
      const answers =
        response.kind === "askUserQuestion" ? response.answers : [];
      const answer =
        answers[0] ??
        (response.kind === "askUserQuestion" ? response.answer : undefined) ??
        "";
      this.emitEvent({
        ts: Date.now(),
        kind: "agent.message",
        payload: { text: `echo: ${answer}` },
      });
    } catch (error) {
      this.emitError(error);
    }
  }

  private async askMultiQuestion(): Promise<void> {
    if (!this.askUser) return this.emitBridgeMissing();
    try {
      const response = await this.askUser({
        sessionId: this.sessionId,
        kind: "askUserQuestion",
        questions: [
          {
            header: "Language",
            question: "Which language?",
            options: [{ label: "Dart" }, { label: "TypeScript" }],
            recommended: 0,
          },
          {
            header: "Tools",
            question: "Which tools?",
            multi: true,
            options: [
              { label: "Simulator" },
              { label: "Server" },
              { label: "Logs" },
            ],
          },
        ],
      });
      this.emitEvent({
        ts: Date.now(),
        kind: "agent.message",
        payload: { text: JSON.stringify(response) },
      });
    } catch (error) {
      this.emitError(error);
    }
  }

  private emitBridgeMissing(): void {
    this.emitEvent({
      ts: Date.now(),
      kind: "session.error",
      payload: { message: "StubAdapter askUser bridge is not configured" },
    });
  }

  private emitError(error: unknown): void {
    this.emitEvent({
      ts: Date.now(),
      kind: "session.error",
      payload: {
        message: error instanceof Error ? error.message : String(error),
      },
    });
  }

  private emitEvent(event: AdapterEvent): void {
    this.emit("event", event);
  }
}
