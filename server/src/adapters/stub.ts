import { EventEmitter } from "node:events";
import type { AdapterEvent, AgentAdapter, SessionCapabilities, SpawnOpts, UserInput } from "./adapter.js";
import { sharedMediaStore } from "../media/store.js";
import { prepareTurnOrFail } from "../media/attach.js";
import type { SessionConfigOption } from "../protocol.js";
import type { UIResponse } from "../uicall.js";

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


    setTimeout(() => {
      this.emitEvent({
        ts: Date.now(),
        kind: "agent.message",
        payload: { text: `echo: ${prompt}` },
      });
    }, echoDelayMs);
  }

  async cancel(): Promise<void> {
    this.emit("status", "idle");
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
