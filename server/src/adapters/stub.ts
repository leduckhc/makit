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
   *  (SPEC-session-lifecycle-resume-list-delete): the manager persists {@link agentSessionId} and re-attaches by it. */
  readonly capabilities: SessionCapabilities = { resume: true, load: false, list: true, delete: true, fork: false, archive: false, close: true };
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
  /**
   * The TOOLS script's pending wait and its abort flag. Same hazard as
   * the deferred turn above but larger: an uncancelled script keeps emitting six starts,
   * six ends, a reply and a second `idle` for the rest of its ~5.5 s — after a
   * `kill()` those land on an adapter that already reported `exit`.
   */
  private toolTimeout?: ReturnType<typeof setTimeout>;
  /**
   * Identity of the TOOLS script currently allowed to emit, bumped on every
   * start and every abort. A script captures its own value and stops the moment
   * it stops matching.
   *
   * Deliberately not a boolean: `cancel()` settles the pending wait (which only
   * *queues* the script's continuation) and then emits `idle` synchronously, and
   * the session layer starts a queued turn on `idle` — so a shared flag was
   * reset to false before the cancelled script resumed, and it went on to emit
   * the rest of its calls interleaved with the new turn.
   */
  private toolRun = 0;
  /**
   * Resolver for the wait currently in flight. Clearing the timer is not enough:
   * its callback is the only thing that resolves the wait, so an aborted script
   * stayed suspended at `await wait(...)` forever, retaining its closure and
   * call data once per cancellation.
   */
  private toolWaitResolve?: () => void;
  /**
   * The in-flight TOOLS script. Exposed so a test can assert it actually settles
   * after a cancel — a suspended async frame emits nothing, so the leak is
   * invisible from the event stream alone.
   */
  toolScript?: Promise<void>;
  /** Set by {@link close} — lets tests assert the graceful path was taken. */
  closed = false;


  /** Turns taken so far — drives the deterministic usage ramp (SPEC-context-usage). */
  private turnCount = 0;

  /**
   * SPEC-cli-as-client (T15): the same turns/gates state machine the real subprocess
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
    // SPEC-user-attachments: the stub takes the SAME delivery path as the real adapters
    // (materialise into the worktree, name the file in the prompt, echo
    // descriptors). Without this the keyless e2e loop would "pass" while
    // exercising nothing, and the dev/demo loop would silently drop images.
    const turn = prepareTurnOrFail(sharedMediaStore(), input, this.workspaceRoot, (e) =>
      this.emitEvent(e),
    );
    if (!turn) return;
    this.emitEvent({ ts: Date.now(), kind: "user.message", payload: turn.echo });
    // SPEC-context-usage: usage must ramp on the SAME path the real adapters take, or the
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

    // STRAY: reproduce the wedge from SPEC-mid-turn-steering-and-queue §Stray post-turn work — the
    // agent streams one chunk with no turn around it, which re-opens a turn whose
    // usual closer (the agent's own settle) is already spent. Nothing here will
    // ever clear it, so it is what `releaseStrayBusy` has to answer for.
    if (prompt.includes("STRAY")) {
      this.emitEvent({
        ts: Date.now(),
        kind: "agent.message",
        payload: { text: "\u{1F4BE} Memory auto-reviewed and updated" },
      });
      this.turns.noteWork();
      return;
    }

    // SPEC-cli-as-client (T15) — the two states `makit wait` must be able to observe, and
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
    // `ms` (default 12s), then idle. The queue (SPEC-mid-turn-steering-and-queue/36) only exists while the
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
    // "TOOLS" → a turn made of tool calls: the one row type the keyless loop
    // could not produce, so the risk branches, durations, exit codes, command
    // summaries and every expanded-body shape (file content, shell output,
    // diff, facts-only) had to be taken on trust. Scripted with real delays so
    // the live counter and the finished-duration gate (SPEC-session-timings) both fire.
    if (input.text.includes("TOOLS")) {
      this.toolScript = this.runToolScript();
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

  /**
   * A representative tool turn: reasoning, a safe read, a multi-command shell
   * call, a grep, an edit (diff body), a failing shell call, and a destructive
   * one. Every `tool.call.start` is closed — a dangling start renders as a row
   * that spins forever.
   */
  private async runToolScript(): Promise<void> {
    this.emit("status", "running");
    // Release any script still in flight first. The token below would stop it
    // emitting, but its pending timer is a shared field: left running, that
    // timer fires later and nulls THIS script's handles, so a subsequent cancel
    // has nothing to clear and the script cannot be aborted at all.
    this.abortToolScript();
    const run = ++this.toolRun;
    const live = () => this.toolRun === run;
    // The two long calls exist so the duration token clears SPEC-session-timings's 2 s floor
    // in the live loop. A unit test only cares about the event shape, so the
    // scale is overridable rather than the script being duplicated.
    const scale = Number(process.env.MAKIT_STUB_TOOL_SCALE ?? "1") || 1;
    const wait = (ms: number) =>
      new Promise<void>((resolve) => {
        this.toolWaitResolve = resolve;
        this.toolTimeout = setTimeout(() => {
          this.toolTimeout = undefined;
          this.toolWaitResolve = undefined;
          resolve();
        }, ms * scale);
      });

    this.emitEvent({
      ts: Date.now(),
      kind: "agent.thinking",
      payload: {
        text:
          "The risk tint fires on edit/write/bash, so it is on for almost every " +
          "row; monochrome loses nothing and buys back the amber for something " +
          "that is actually exceptional.",
      },
    });
    await wait(60);

    type Call = {
      name: string;
      args: Record<string, unknown>;
      risk: "safe" | "risky" | "destructive";
      /** Milliseconds the call "takes" — drives the duration token. */
      ms: number;
      exitCode?: number;
      summary: string;
      output?: string;
    };

    const calls: Call[] = [
      {
        name: "read",
        args: { path: `${this.workspaceRoot}/app/lib/ui/session/tool_call_card.dart` },
        risk: "safe",
        ms: 40,
        summary: "307 lines read",
        output:
          "import 'package:flutter/material.dart';\n" +
          "import 'package:flutter_riverpod/flutter_riverpod.dart';\n\n" +
          "class ToolCallCard extends ConsumerStatefulWidget {\n" +
          "  const ToolCallCard({super.key, required this.item});\n",
      },
      {
        name: "bash",
        args: {
          command: `cd ${this.workspaceRoot} && grep -rn "risk" server/src/*.ts | head -20`,
        },
        risk: "risky",
        ms: 2600,
        summary: "3 matches",
        output:
          "server/src/pi-sessions.ts:259:function classifyRisk(name: string) {\n" +
          "server/src/adapters/acp-map.ts:540:function riskFromKind(kind) {\n" +
          'server/src/adapters/codex-map.ts:29:type Risk = "safe" | "risky";',
      },
      {
        name: "grep",
        args: { pattern: "kToolRiskyColor", glob: "*.dart" },
        risk: "safe",
        ms: 30,
        summary: "1 match",
        output: "app/lib/ui/session/chat_metrics.dart:46:const Color kToolRiskyColor",
      },
      {
        name: "edit",
        args: {
          path: "app/lib/ui/session/tool_call_card.dart",
          oldText: "        size: 16,\n        color: riskColor,",
          newText: "        size: kToolGlyph,\n        color: riskColor,",
        },
        risk: "risky",
        ms: 40,
        summary: "+1 −1",
      },
      {
        name: "bash",
        args: { command: "sed -i '' 's/Ran/Run/g' app/lib/ui/session/tool_renderers.dart" },
        risk: "risky",
        ms: 300,
        exitCode: 1,
        summary: "exit 1",
        output: 'sed: 1: "s/Ran/Run/g": invalid command code R',
      },
      {
        name: "bash",
        args: { command: "rm -rf ~/Library/Caches/dev.getmakit.app && rm -rf build" },
        risk: "destructive",
        ms: 2200,
        summary: "removed 2 paths",
      },
    ];

    for (const [i, call] of calls.entries()) {
      if (!live()) return;
      const callId = `stub-tool-${Date.now()}-${i}`;
      this.emitEvent({
        ts: Date.now(),
        kind: "tool.call.start",
        payload: { callId, name: call.name, args: call.args, risk: call.risk },
      });
      await wait(call.ms);
      // Closing the call is not optional — a dangling start spins forever — but
      // an aborted script must not open the next one either, so the guard sits
      // on both sides of the wait.
      if (!live()) return;
      this.emitEvent({
        ts: Date.now(),
        kind: "tool.call.end",
        payload: {
          callId,
          exitCode: call.exitCode ?? 0,
          summary: call.summary,
          output: call.output ?? "",
        },
      });
      await wait(40);
    }
    if (!live()) return;

    this.emitEvent({
      ts: Date.now(),
      kind: "agent.message",
      payload: { text: "Rows are 31px now, one family, and the amber is gone." },
    });
    this.emit("status", "idle");
  }

  /** No mid-turn injection (SPEC-mid-turn-steering-and-queue): the session layer queues instead. */
  async steer(_input: UserInput): Promise<boolean> {
    return false;
  }

  /**
   * Same answer the real subprocess adapters give (SPEC-mid-turn-steering-and-queue): the stub owns the
   * same tracker, so a turn one stray chunk opened is releasable here too. The
   * `STRAY` script is how both e2e loops reach it.
   */
  releaseStrayBusy(): boolean {
    return this.turns.releaseStrayWork();
  }

  async cancel(): Promise<void> {
    // Both kinds of deferred work are cancelled: a SLOW/FAIL_TURN completion and
    // a TOOLS script mid-flight. Either left running would emit into the turn
    // that replaces this one.
    const settled = this.clearPendingTurn();
    this.abortToolScript();
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
   * Release a parked gate (SPEC-cli-as-client T15) without emitting the intermediate
   * "running" that `leaveApproval` would otherwise produce: drop the TURN first
   * so the tracker has nothing to resume to, then the gate. A cancel that left
   * the gate counted would wedge the session for good — `settleIdle` could never
   * fire again, so every later turn would look stuck.
   *
   * The settle is `leaveApproval`'s own job as of SPEC-session-lifecycle-resume-list-delete: it now settles to
   * `idle` when the last gate closes and no turn remains (it used to only resume
   * `running`, which pinned a session whose turn ended before its gate). So this
   * must NOT settle again — doing so emitted `idle` twice for one cancel.
   *
   * Returns whether there was a gate to release. Called both by `cancel` and when
   * the user *answers* the prompt that raised the gate.
   */
  private releaseGate(): boolean {
    if (this.gatedTurn === undefined) return false;
    this.turns.leaveTurn(this.gatedTurn);
    this.gatedTurn = undefined;
    this.turns.leaveApproval();
    return true;
  }

  /** Stop an in-flight TOOLS script: clear its pending wait, block the rest. */
  private abortToolScript(): void {
    // Bumping the token invalidates the in-flight script for good: a later start
    // takes a new value, so the cancelled one can never be revalidated.
    this.toolRun++;
    if (this.toolTimeout !== undefined) {
      clearTimeout(this.toolTimeout);
      this.toolTimeout = undefined;
    }
    // Settle the wait so the script resumes, sees the flag and returns. Without
    // this it never runs again and its frame is never released.
    this.toolWaitResolve?.();
    this.toolWaitResolve = undefined;
  }

  /**
   * Graceful close. The stub has no agent-side state to release, but it records
   * the call and cancels like the real thing so the keyless e2e loop can prove
   * the close path runs end-to-end (`test/e2e-server.ts --mode stub`).
   */
  async close(): Promise<void> {
    this.closed = true;
    await this.cancel();
  }

  /**
   * Deterministic `session.usage` ramp (SPEC-context-usage): a fixed per-turn context cost
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

  /** SPEC-acp-config-options-unified-composer: a tiny deterministic config catalog so keyless e2e runs can
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
    this.abortToolScript();
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
