import { EventEmitter } from "node:events";
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
export class StubAdapter extends EventEmitter {
    agent = "stub";
    sessionId = "";
    askUser;
    constructor(options = {}) {
        super();
        this.askUser = options.askUser;
    }
    async start(opts) {
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
    async send(input) {
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
                }
                else {
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
                payload: { text: `echo: ${input.text}` },
            });
        }, echoDelayMs);
    }
    async cancel() {
        this.emit("status", "idle");
    }
    async kill() {
        this.emit("exit", null);
    }
    async askSingleQuestion() {
        if (!this.askUser)
            return this.emitBridgeMissing();
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
            const answers = response.kind === "askUserQuestion" ? response.answers : [];
            const answer = answers[0] ??
                (response.kind === "askUserQuestion" ? response.answer : undefined) ??
                "";
            this.emitEvent({
                ts: Date.now(),
                kind: "agent.message",
                payload: { text: `echo: ${answer}` },
            });
        }
        catch (error) {
            this.emitError(error);
        }
    }
    async askMultiQuestion() {
        if (!this.askUser)
            return this.emitBridgeMissing();
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
        }
        catch (error) {
            this.emitError(error);
        }
    }
    emitBridgeMissing() {
        this.emitEvent({
            ts: Date.now(),
            kind: "session.error",
            payload: { message: "StubAdapter askUser bridge is not configured" },
        });
    }
    emitError(error) {
        this.emitEvent({
            ts: Date.now(),
            kind: "session.error",
            payload: {
                message: error instanceof Error ? error.message : String(error),
            },
        });
    }
    emitEvent(event) {
        this.emit("event", event);
    }
}
//# sourceMappingURL=stub.js.map