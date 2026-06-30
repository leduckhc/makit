import { EventEmitter } from "node:events";
import type { AdapterEvent, AgentAdapter, SpawnOpts, UserInput } from "./adapter.js";
import type { UIResponse } from "../uicall.js";

export interface StubAdapterOptions {
  askUser?: (body: Record<string, unknown>) => Promise<UIResponse>;
}

const echoDelayMs = 50;

/// Deterministic in-process adapter used by `e2e-server.ts --mode=stub`.
/// No subprocess, no LLM, no flakiness — scripted replies based on user text:
///   - "ASK_MULTI"     → multi-question / multi-select askUserQuestion round-trip
///   - "ASK_QUESTION"  → single-question askUserQuestion round-trip
///   - anything else   → `echo: <text>` after 50ms
export class StubAdapter extends EventEmitter implements AgentAdapter {
  readonly agent = "stub";

  private sessionId = "";
  private askUser?: (body: Record<string, unknown>) => Promise<UIResponse>;

  constructor(options: StubAdapterOptions = {}) {
    super();
    this.askUser = options.askUser;
  }

  async start(opts: SpawnOpts): Promise<void> {
    this.sessionId = opts.sessionId ?? "";
    this.emit("status", "idle");
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
    this.emitEvent({
      ts: Date.now(),
      kind: "user.message",
      payload: { text: input.text },
    });

    if (input.text.includes("ASK_MULTI")) {
      await this.askMultiQuestion();
      return;
    }
    if (input.text.includes("ASK_QUESTION")) {
      await this.askSingleQuestion();
      return;
    }

    setTimeout(() => {
      this.emitEvent({
        ts: Date.now(),
        kind: "agent.message",
        payload: { text: `echo: ${input.text}` },
      });
    }, echoDelayMs);
  }

  async cancel(): Promise<void> {
    this.emit("status", "idle");
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
