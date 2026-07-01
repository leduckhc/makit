import { EventEmitter } from "node:events";
const echoDelayMs = 50;
/// Deterministic in-process adapter used by `e2e-server.ts --mode=stub`.
/// No subprocess, no LLM, no flakiness — scripted replies based on user text:
///   - "ASK_MULTI"     → multi-question / multi-select askUserQuestion round-trip
///   - "ASK_QUESTION"  → single-question askUserQuestion round-trip
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