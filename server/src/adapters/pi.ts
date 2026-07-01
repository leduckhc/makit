/**
 * PiAdapter — drives `pi --mode rpc` as a long-running JSON-RPC subprocess.
 *
 * Compared to the previous `--mode json -p` adapter, this gives us:
 *   - All of pi's slash commands, skills, extensions, prompt templates
 *     (they only activate in the long-running modes)
 *   - Mid-turn steering — phone messages sent while the agent is busy are
 *     queued as `steer` instead of dropped
 *   - Abort, model switching, compaction, follow-up queueing
 *
 * Lifetime: one pi process per pino Session, started lazily on first send,
 * killed on Session shutdown.
 *
 * Framing: per pi's rpc.md, we MUST split on `\n` only — Node's `readline`
 * also splits on U+2028/U+2029 which are valid inside JSON strings. So we
 * roll a tiny LF-only splitter over the raw stdout stream.
 */

/* eslint-disable @typescript-eslint/no-explicit-any */

import { spawn, type ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
// (no path/url imports needed — pi binary is resolved from PATH)
import type { AdapterEvent, AgentAdapter, SpawnOpts, UserInput } from "./adapter.js";

export class PiAdapter extends EventEmitter implements AgentAdapter {
  readonly agent = "pi";

  private cwd = process.cwd();
  private piSessionId = randomUUID();
  private child?: ChildProcess;
  private extraEnv: Record<string, string> = {};
  private extensions: string[] = [];
  private sessionId = "";
  private askUser?: import("../uicall.js").AskUser;

  /** True while pi is mid-turn — i.e. between turn_start and the matching agent_end. */
  private isStreaming = false;

  /** Accumulates text per content-index, flushed at text_end. */
  private textBuffers = new Map<number, string>();

  async start(opts: SpawnOpts): Promise<void> {
    this.cwd = opts.cwd;
    this.extraEnv = opts.env ?? {};
    this.extensions = opts.extensions ?? [];
    this.sessionId = opts.sessionId ?? "";
    this.askUser = opts.askUser;
    await this.ensureProcess();
    this.emit("status", "idle");
  }

  async send(input: UserInput): Promise<void> {
    await this.ensureProcess();

    // Echo the user message into our event log so transcripts are complete.
    this.emitEvent({
      ts: Date.now(),
      kind: "user.message",
      payload: { text: input.text },
    });

    const cmd: any = {
      id: `prompt-${Date.now()}`,
      type: "prompt",
      message: input.text,
    };
    // If pi is mid-turn, queue as a steering message rather than rejecting.
    if (this.isStreaming) cmd.streamingBehavior = "steer";

    this.writeCommand(cmd);
  }

  async cancel(): Promise<void> {
    if (this.child) this.writeCommand({ type: "abort" });
  }

  async kill(signal: NodeJS.Signals = "SIGTERM"): Promise<void> {
    if (this.child) this.child.kill(signal);
    this.child = undefined;
    this.emit("exit", null);
  }

  // ---- subprocess lifecycle ------------------------------------------------

  private async ensureProcess(): Promise<void> {
    if (this.child && !this.child.killed) return;

    const args = ["--mode", "rpc", "--session-id", this.piSessionId];
    for (const ext of this.extensions) {
      args.push("-e", ext);
    }
    // The real pi coding agent (@earendil-works/pi-coding-agent) — resolved
    // from PATH (e.g. /opt/homebrew/bin/pi) or an explicit override. NOTE: do
    // NOT use node_modules/.bin/pi — that resolves to the unrelated "pi" npm
    // package (a trivial stub that just prints "3" and exits).
    const piBin = process.env.PINO_PI_BIN || "pi";
    const child = spawn(piBin, args, {
      cwd: this.cwd,
      env: { ...process.env, ...this.extraEnv },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;

    // pi.stdout — JSON-line stream of events and command responses.
    bindLfLines(child.stdout!, (line) => this.handleLine(line));

    // pi.stderr — pi's own diagnostic output. Forward to our log; if it's
    // really bad, surface as a session.error.
    let stderrBuf = "";
    child.stderr!.on("data", (chunk: Buffer) => {
      const s = chunk.toString();
      stderrBuf += s;
      if (stderrBuf.length > 8192) stderrBuf = stderrBuf.slice(-8192);
      process.stderr.write(`[pi] ${s}`);
    });

    child.on("exit", (code, signal) => {
      this.isStreaming = false;
      const wasAlive = !!this.child;
      this.child = undefined;
      if (wasAlive) {
        if (code !== 0 && code !== null) {
          this.emitEvent({
            ts: Date.now(),
            kind: "session.error",
            payload: {
              message: `pi exited with code ${code}${signal ? ` (${signal})` : ""}: ${stderrBuf.slice(-500)}`,
            },
          });
        }
        // Don't emit("status","idle") here — the session has actually exited,
        // not gone idle. The emitEvent below conveys the right status and
        // Session.status will be updated from the event-log replay path.
        this.emitEvent({
          ts: Date.now(),
          kind: "session.status",
          payload: { status: "exited" },
        });
        this.emit("exit", code);
      }
    });

    // Give pi a moment to initialize, then ask for available commands so the
    // app can populate its slash palette with real extensions/skills/prompts.
    await new Promise((r) => setTimeout(r, 100));
    this.writeCommand({ id: "boot-commands", type: "get_commands" });
  }

  private writeCommand(cmd: Record<string, unknown>): void {
    const stdin = this.child?.stdin;
    if (!stdin || stdin.destroyed) return;
    stdin.write(JSON.stringify(cmd) + "\n");
  }

  /**
   * Transport a pi `extension_ui_request` to the phone and reply with an
   * `extension_ui_response`. Maps pi's ui methods → canonical UICall → app,
   * then the app's answer → the per-method response shape pi expects:
   *   select  → { value } | { cancelled }
   *   confirm → { confirmed } | { cancelled }
   *   input   → { value } | { cancelled }
   *   editor  → { value } | { cancelled }
   * Fire-and-forget methods (notify/setStatus/…) need no reply.
   */
  private async handleUiRequest(evt: any): Promise<void> {
    const id: string = evt.id;
    const method: string = evt.method;
    const reply = (fields: Record<string, unknown>) =>
      this.writeCommand({ type: "extension_ui_response", id, ...fields });

    // Fire-and-forget UI methods — no response expected.
    if (["notify", "setStatus", "setWidget", "setTitle", "set_editor_text"].includes(method)) {
      return;
    }

    // No phone attached → cancel so pi doesn't hang.
    if (!this.askUser) {
      reply({ cancelled: true });
      return;
    }

    try {
      switch (method) {
        case "select": {
          const options: string[] = Array.isArray(evt.options) ? evt.options : [];
          const resp = await this.askUser({
            kind: "askUserQuestion",
            sessionId: this.sessionId,
            questions: [
              {
                header: "Select",
                question: String(evt.title ?? "Pick one"),
                options: options.map((label) => ({ label: String(label) })),
              },
            ],
          });
          if (resp.kind === "askUserQuestion" && !(resp as any).cancelled && resp.answers?.[0]) {
            reply({ value: resp.answers[0] });
          } else {
            reply({ cancelled: true });
          }
          return;
        }
        case "confirm": {
          const resp = await this.askUser({
            kind: "confirmAction",
            sessionId: this.sessionId,
            title: String(evt.title ?? "Confirm"),
            message: String(evt.message ?? ""),
            action: "confirm",
          });
          if (resp.kind === "confirmAction" && !(resp as any).cancelled) {
            reply({ confirmed: resp.approved });
          } else {
            reply({ cancelled: true });
          }
          return;
        }
        case "input":
        case "editor": {
          const resp = await this.askUser({
            kind: "input",
            sessionId: this.sessionId,
            title: String(evt.title ?? (method === "editor" ? "Edit" : "Input")),
            placeholder: typeof evt.placeholder === "string" ? evt.placeholder : undefined,
            prefill: typeof evt.prefill === "string" ? evt.prefill : undefined,
            multiline: method === "editor",
          });
          if (resp.kind === "input" && !resp.cancelled && typeof resp.value === "string") {
            reply({ value: resp.value });
          } else {
            reply({ cancelled: true });
          }
          return;
        }
        default:
          // custom (pi never emits it in rpc) or unknown → cancel.
          reply({ cancelled: true });
      }
    } catch (e) {
      console.log(`[pino] ui interceptor error (${method}): ${(e as Error).message}`);
      reply({ cancelled: true });
    }
  }

  // ---- pi → wire mapping --------------------------------------------------

  private handleLine(line: string): void {
    if (!line.trim()) return;
    let evt: any;
    try {
      evt = JSON.parse(line);
    } catch {
      return;
    }
    if (!evt || typeof evt !== "object") return;

    console.log(`[pi.line] type=${evt.type}${evt.assistantMessageEvent ? " sub=" + evt.assistantMessageEvent.type : ""}`);

    // UI interceptor: pi extensions calling ctx.ui.select/confirm/input/editor
    // emit an extension_ui_request and block until we reply. Transport it to
    // the phone and write back an extension_ui_response. See docs/UI-TRANSPORT.md.
    if (evt.type === "extension_ui_request") {
      void this.handleUiRequest(evt);
      return;
    }

    switch (evt.type) {
      case "response":
        if (evt.command === "get_commands" && evt.success && evt.data?.commands) {
          this.emitEvent({
            ts: Date.now(),
            kind: "session.commands",
            payload: { commands: evt.data.commands },
          });
        }
        return;

      case "session":
      case "agent_start":
      case "message_start":
      case "message_end":
      case "queue_update":
      case "compaction_start":
      case "compaction_end":
      case "auto_retry_start":
      case "auto_retry_end":
        return;

      case "turn_start":
        this.isStreaming = true;
        this.emit("status", "running");
        return;

      case "turn_end":
        // Stay "streaming" — agent may have more tool calls / turns ahead.
        return;

      case "agent_end":
        this.isStreaming = false;
        // Status emit alone — Session synthesises the corresponding
        // session.status SessionEvent. Emitting emitEvent here too would
        // double-fire the event to subscribed clients.
        this.emit("status", "idle");
        return;

      case "message_update": {
        const e = evt.assistantMessageEvent;
        if (!e || typeof e !== "object") return;
        const idx: number = typeof e.contentIndex === "number" ? e.contentIndex : 0;
        if (e.type === "text_start") {
          this.textBuffers.set(idx, "");
        } else if (e.type === "text_delta") {
          const prev = this.textBuffers.get(idx) ?? "";
          this.textBuffers.set(idx, prev + (typeof e.delta === "string" ? e.delta : ""));
        } else if (e.type === "text_end") {
          const text =
            this.textBuffers.get(idx) ??
            (typeof e.content === "string" ? e.content : "");
          this.textBuffers.delete(idx);
          if (text.length > 0) {
            this.emitEvent({
              ts: Date.now(),
              kind: "agent.message",
              payload: { text },
            });
          }
        }
        return;
      }

      case "tool_execution_start": {
        const callId = String(evt.toolCallId ?? `c-${Date.now()}`);
        const name = String(evt.toolName ?? "tool");
        const args = evt.args ?? {};
        this.emitEvent({
          ts: Date.now(),
          kind: "tool.call.start",
          payload: { callId, name, args, risk: classifyRisk(name) },
        });
        return;
      }

      case "tool_execution_update": {
        const callId = String(evt.toolCallId ?? "");
        if (!callId || evt.partialResult === undefined) return;
        this.emitEvent({
          ts: Date.now(),
          kind: "tool.call.delta",
          payload: { callId, chunk: stringifyDelta(evt.partialResult) },
        });
        return;
      }

      case "tool_execution_end": {
        const callId = String(evt.toolCallId ?? "");
        const output = extractResultText(evt.result);
        this.emitEvent({
          ts: Date.now(),
          kind: "tool.call.end",
          payload: {
            callId,
            exitCode: evt.isError ? 1 : 0,
            // summary = first non-empty line for the collapsed card; output =
            // the full result text for the detail view.
            summary: summarizeText(evt.toolName, output),
            output,
          },
        });
        return;
      }

      default:
        return;
    }
  }

  private emitEvent(e: AdapterEvent) {
    console.log(`[pino] pi.emitEvent kind=${e.kind}`);
    this.emit("event", e);
  }
}

// ---------- helpers ---------------------------------------------------------

/**
 * LF-only line splitter — required by pi's RPC mode framing rules. We can't
 * use `readline` because it also splits on U+2028/U+2029 which are valid
 * inside JSON strings.
 */
function bindLfLines(stream: NodeJS.ReadableStream, onLine: (line: string) => void): void {
  let buf = "";
  stream.setEncoding?.("utf8");
  stream.on("data", (chunk: string | Buffer) => {
    buf += typeof chunk === "string" ? chunk : chunk.toString("utf8");
    let i: number;
    while ((i = buf.indexOf("\n")) !== -1) {
      let line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      onLine(line);
    }
  });
  stream.on("end", () => {
    if (buf.length > 0) onLine(buf);
  });
}

function stringifyDelta(v: unknown): string {
  if (typeof v === "string") return v;
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

/**
 * Pull human-readable text out of a pi tool result. pi returns several shapes:
 *   - a plain string
 *   - `{ content: [{ type: "text", text: "…" }, …] }`  (most tools)
 *   - `{ stdout: "…" }` or `{ summary: "…" }`
 * Falls back to compact JSON so nothing is silently dropped.
 */
function extractResultText(result: unknown): string {
  if (result == null) return "";
  if (typeof result === "string") return result;
  if (typeof result === "object") {
    const r = result as Record<string, unknown>;
    if (Array.isArray(r.content)) {
      const parts = r.content
        .map((c) =>
          c && typeof c === "object" && typeof (c as any).text === "string"
            ? (c as any).text
            : "",
        )
        .filter((s) => s.length > 0);
      if (parts.length > 0) return parts.join("\n");
    }
    if (typeof r.summary === "string") return r.summary;
    if (typeof r.stdout === "string") return r.stdout;
  }
  try {
    return JSON.stringify(result);
  } catch {
    return String(result);
  }
}

/** First non-empty line of [text], truncated for the collapsed card. */
function summarizeText(toolName: unknown, text: string): string {
  const name = String(toolName ?? "tool");
  const firstLine = text.split("\n").map((l) => l.trim()).find((l) => l.length > 0) ?? "";
  if (!firstLine) return `${name} ok`;
  return firstLine.length > 120 ? `${firstLine.slice(0, 117)}…` : firstLine;
}

function classifyRisk(name: string): "safe" | "risky" | "destructive" {
  switch (name) {
    case "read":
    case "ls":
    case "grep":
    case "find":
      return "safe";
    case "edit":
    case "write":
    case "bash":
      return "risky";
    default:
      return "safe";
  }
}
