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
 * Lifetime: one pi process per makit Session, started lazily on first send,
 * killed on Session shutdown.
 *
 * Framing: per pi's rpc.md, we MUST split on `\n` only — Node's `readline`
 * also splits on U+2028/U+2029 which are valid inside JSON strings. So we
 * roll a tiny LF-only splitter over the raw stdout stream.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { randomUUID } from "node:crypto";
// (no path/url imports needed — pi binary is resolved from PATH)
import type { SpawnOpts, UserInput } from "./adapter.js";
import { SubprocessAdapter } from "./subprocess-adapter.js";
import { spawnLineProcess, type ChildExitInfo, type ChildLineTransport } from "./child_transport.js";
import { summarizeLine } from "./summarize.js";
import { isRecord, parseJsonLine } from "./wire.js";
import { log } from "../log.js";
import { newId } from "../protocol.js";

export class PiAdapter extends SubprocessAdapter {
  readonly agent = "pi";

  private cwd = process.cwd();
  private piSessionId = randomUUID();
  /** Live subprocess transport; undefined before first spawn and after exit. */
  private transport?: ChildLineTransport;
  /** Test-only seam: unit tests inject a fake `child` and drive writeCommand. */
  private child?: ChildProcess;
  private extraEnv: Record<string, string> = {};
  private extensions: string[] = [];
  private sessionId = "";
  private askUser?: import("../uicall.js").AskUser;
  private resumeSessionPath?: string;
  private model?: string;

  /** Injectable spawn (tests provide a fake); defaults to node's child_process. */
  private readonly _spawn: typeof spawn;

  constructor(opts: { spawn?: typeof spawn } = {}) {
    super();
    this._spawn = opts.spawn ?? spawn;
  }

  /** True while pi is mid-turn — i.e. between turn_start and the matching agent_end. */
  private isStreaming = false;

  /** Accumulates text per content-index, flushed at text_end. */
  private textBuffers = new Map<number, string>();

  /** Stable streamed-message id per content-index (ties deltas to the final). */
  private msgIds = new Map<number, string>();

  /** Accumulates reasoning/thinking text per content-index, flushed at end. */
  private thinkingBuffers = new Map<number, string>();

  /** Stable streamed-thinking id per content-index (ties deltas to the final). */
  private thinkIds = new Map<number, string>();

  // ---- session.meta (model / thinking / selectable models) ----------------
  // pi reports these via the `get_state` + `get_available_models` rpc commands
  // (see docs/rpc.md). We cache the latest of each and emit a merged
  // `session.meta` event whenever either changes, so the app can drive its
  // model + thinking selectors. Nothing emitted pi-mirror-style anymore
  // (#26 removed the extension), so the adapter owns this now.
  private metaModel: MetaModel | null = null;
  private metaThinking = "";
  private metaModels: MetaModel[] = [];

  async start(opts: SpawnOpts): Promise<void> {
    this.cwd = opts.cwd;
    this.extraEnv = opts.env ?? {};
    this.extensions = opts.extensions ?? [];
    this.sessionId = opts.sessionId ?? "";
    this.askUser = opts.askUser;
    this.resumeSessionPath = opts.resumeSessionPath;
    this.model = opts.model;
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

    const cmd: { id: string; type: string; message: string; streamingBehavior?: string } = {
      id: `prompt-${Date.now()}`,
      type: "prompt",
      message: input.text,
    };
    // If pi is mid-turn, queue as a steering message rather than rejecting.
    if (this.isStreaming) cmd.streamingBehavior = "steer";

    this.writeCommand(cmd);
  }

  async sendAction(action: string, args?: Record<string, unknown>): Promise<void> {
    await this.ensureProcess();
    // `name` → persist the session name in pi so it survives resume/re-attach.
    if (action === "name") {
      const name = typeof args?.name === "string" ? args.name.trim() : "";
      if (name) this.writeCommand({ type: "set_session_name", name });
      return;
    }
    // `model` → switch the active model; the response carries the new Model and
    // triggers a fresh session.meta (see handleLine).
    if (action === "model") {
      const provider = typeof args?.provider === "string" ? args.provider : "";
      const id = typeof args?.id === "string" ? args.id : "";
      if (provider && id) {
        this.writeCommand({ type: "set_model", provider, modelId: id });
      }
      return;
    }
    // `thinking` → set the reasoning level; re-query state after so the emitted
    // meta reflects what pi actually applied (some levels are model-gated).
    if (action === "thinking") {
      const level = typeof args?.level === "string" ? args.level : "";
      if (level) this.writeCommand({ type: "set_thinking_level", level });
      return;
    }
    // Other actions (compact/…) are not yet mapped in rpc mode.
  }

  async cancel(): Promise<void> {
    if (this.transport) this.writeCommand({ type: "abort" });
  }

  async kill(_signal: NodeJS.Signals = "SIGTERM"): Promise<void> {
    this.transport?.dispose();
    this.transport = undefined;
    this.child = undefined;
    this.emit("exit", null);
  }

  // ---- subprocess lifecycle ------------------------------------------------

  private async ensureProcess(): Promise<void> {
    if (this.transport) return;
    // Test seam: unit tests inject a fake `child` directly (no spawned
    // transport) to drive writeCommand. A live seam must not trigger a real
    // spawn — this mirrors the pre-transport guard `this.child && !killed`.
    if (this.child && !this.child.killed) return;

    const args = this.resumeSessionPath
      ? ["--mode", "rpc", "--session", this.resumeSessionPath]
      : ["--mode", "rpc", "--session-id", this.piSessionId];
    if (this.model) {
      args.push("--model", this.model);
    }
    for (const ext of this.extensions) {
      // A removed/renamed extension must not take down the whole pi session:
      // pi hard-exits (code 1) if an `-e <path>` no longer exists on disk.
      if (!existsSync(ext)) {
        log.warn(`[makit] skipping missing pi extension: ${ext}`);
        continue;
      }
      args.push("-e", ext);
    }
    // The real pi coding agent (@earendil-works/pi-coding-agent) — resolved
    // from PATH (e.g. /opt/homebrew/bin/pi) or an explicit override. NOTE: do
    // NOT use node_modules/.bin/pi — that resolves to the unrelated "pi" npm
    // package (a trivial stub that just prints "3" and exits).
    const piBin = process.env.MAKIT_PI_BIN || "pi";
    const transport = spawnLineProcess({
      command: piBin,
      args,
      cwd: this.cwd,
      env: this.extraEnv,
      label: "pi",
      spawn: this._spawn,
    });
    this.transport = transport;

    // pi.stdout — JSON-line stream of events and command responses.
    transport.onLine((line) => this.handleLine(line));
    // The shared transport swallows async stream faults and settles the exit
    // (buffering the code until this listener registers). We only add the
    // pi-specific domain reaction here.
    transport.onExit((code, info) => this.onChildExit(code, info));

    // Give pi a moment to initialize, then ask for available commands so the
    // app can populate its slash palette with real extensions/skills/prompts,
    // plus the model/thinking state that drives the composer selectors.
    await new Promise((r) => setTimeout(r, 100));
    this.writeCommand({ id: "boot-commands", type: "get_commands" });
    this.requestMeta();
  }

  /**
   * pi-specific reaction to the subprocess exiting or faulting. The daemon-
   * safety plumbing (settle-once, error swallowing) lives in the shared
   * transport; here we translate the exit into session events and drop the
   * transport so the next send() re-spawns.
   */
  private onChildExit(code: number | null, info: ChildExitInfo): void {
    this.isStreaming = false;
    const wasAlive = !!this.transport;
    this.transport = undefined;
    this.child = undefined;
    if (!wasAlive) return; // kill() already tore the process down
    if (info.error) {
      this.emitEvent({
        ts: Date.now(),
        kind: "session.error",
        payload: { message: `pi process error: ${info.error.message}` },
      });
    } else if (code !== 0 && code !== null) {
      this.emitEvent({
        ts: Date.now(),
        kind: "session.error",
        payload: {
          message: `pi exited with code ${code}${info.signal ? ` (${info.signal})` : ""}: ${info.stderrTail.slice(-500)}`,
        },
      });
    }
    // Don't emit("status","idle") here — the session has actually exited, not
    // gone idle. The event below conveys the right status and Session.status
    // is updated from the event-log replay path.
    this.emitEvent({
      ts: Date.now(),
      kind: "session.status",
      payload: { status: "exited" },
    });
    this.emit("exit", code);
  }

  /**
   * Ask pi for its current model + thinking level ([get_state]) and the list of
   * selectable models ([get_available_models]). Their responses are handled in
   * [handleLine] and merged into a single `session.meta` event via [pushMeta].
   */
  private requestMeta(): void {
    this.writeCommand({ id: "meta-state", type: "get_state" });
    this.writeCommand({ id: "meta-models", type: "get_available_models" });
  }

  /** Emit the current cached model/thinking/models snapshot as `session.meta`. */
  private pushMeta(): void {
    this.emitEvent({
      ts: Date.now(),
      kind: "session.meta",
      payload: {
        model: this.metaModel,
        thinking: this.metaThinking,
        models: this.metaModels,
      },
    });
  }

  private writeCommand(cmd: Record<string, unknown>): void {
    const line = JSON.stringify(cmd);
    if (this.transport) {
      this.transport.send(line);
      return;
    }
    // Fallback path for unit tests that inject a fake `child` directly (no
    // spawned transport). Production always has a transport.
    const stdin = this.child?.stdin;
    if (!stdin || stdin.destroyed) return;
    try {
      stdin.write(line + "\n");
    } catch (err) {
      // A synchronous write throw (stream torn down between the guard and the
      // write) must not crash the daemon.
      log.warn(`[makit] pi stdin write failed: ${(err as Error).message}`);
    }
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
  private async handleUiRequest(evt: PiFrame): Promise<void> {
    const id = String(evt.id);
    const method = String(evt.method);
    const reply = (fields: Record<string, unknown>) =>
      this.writeCommand({ type: "extension_ui_response", id, ...fields });

    // setTitle → surface as an agent-driven session rename. Other
    // fire-and-forget UI methods are display-only and need no response.
    if (method === "setTitle") {
      const t = typeof evt.title === "string" ? evt.title.trim() : "";
      if (t) this.emit("title", t);
      return;
    }
    if (["notify", "setStatus", "setWidget", "set_editor_text"].includes(method)) {
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
          if (resp.kind === "askUserQuestion" && !(resp as { cancelled?: boolean }).cancelled && resp.answers?.[0]) {
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
          if (resp.kind === "confirmAction" && !(resp as { cancelled?: boolean }).cancelled) {
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
      log.warn(`[makit] ui interceptor error (${method}): ${(e as Error).message}`);
      reply({ cancelled: true });
    }
  }

  // ---- pi → wire mapping --------------------------------------------------

  private handleLine(line: string): void {
    const parsed = parseJsonLine(line);
    if (!isRecord(parsed)) return;
    const evt = parsed as PiFrame;

    log.debug(`[pi.line] type=${evt.type}${evt.assistantMessageEvent ? " sub=" + evt.assistantMessageEvent.type : ""}`);

    // UI interceptor: pi extensions calling ctx.ui.select/confirm/input/editor
    // emit an extension_ui_request and block until we reply. Transport it to
    // the phone and write back an extension_ui_response. See docs/UI-TRANSPORT.md.
    if (evt.type === "extension_ui_request") {
      void this.handleUiRequest(evt);
      return;
    }

    switch (evt.type) {
      case "response": {
        const data = isRecord(evt.data) ? evt.data : undefined;
        if (evt.command === "get_commands" && evt.success && data?.commands) {
          this.emitEvent({
            ts: Date.now(),
            kind: "session.commands",
            payload: { commands: data.commands },
          });
        } else if (evt.command === "get_state" && evt.success && data) {
          this.metaModel = normalizeModel(data.model);
          if (typeof data.thinkingLevel === "string") {
            this.metaThinking = data.thinkingLevel;
          }
          this.pushMeta();
        } else if (
          evt.command === "get_available_models" &&
          evt.success &&
          Array.isArray(data?.models)
        ) {
          this.metaModels = data.models
            .map(normalizeModel)
            .filter((m: unknown): m is MetaModel => m !== null);
          this.pushMeta();
        } else if (evt.command === "set_model" && evt.success) {
          // Response data is the new Model; adopt it and re-query state so the
          // thinking level (which pi may adjust per-model) stays accurate.
          const m = normalizeModel(evt.data);
          if (m) this.metaModel = m;
          this.requestMeta();
        } else if (evt.command === "set_thinking_level" && evt.success) {
          // No payload on this response — re-query for the applied level.
          this.requestMeta();
        }
        return;
      }

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
          this.msgIds.set(idx, newId("am"));
          this.textBuffers.set(idx, "");
        } else if (e.type === "text_delta") {
          const delta = typeof e.delta === "string" ? e.delta : "";
          this.textBuffers.set(idx, (this.textBuffers.get(idx) ?? "") + delta);
          // Stream the token to the phone so the bubble grows live.
          const msgId = this.msgIds.get(idx);
          if (msgId && delta.length > 0) {
            this.emitEvent({
              ts: Date.now(),
              kind: "agent.message.delta",
              payload: { msgId, chunk: delta },
            });
          }
        } else if (e.type === "text_end") {
          const text =
            this.textBuffers.get(idx) ??
            (typeof e.content === "string" ? e.content : "");
          const msgId = this.msgIds.get(idx);
          this.textBuffers.delete(idx);
          this.msgIds.delete(idx);
          if (text.length > 0) {
            // Final authoritative message — carries msgId so the app finalizes
            // the streamed bubble instead of appending a duplicate.
            this.emitEvent({
              ts: Date.now(),
              kind: "agent.message",
              payload: { text, ...(msgId ? { msgId } : {}) },
            });
          }
        } else if (e.type === "thinking_start") {
          this.thinkIds.set(idx, newId("th"));
          this.thinkingBuffers.set(idx, "");
        } else if (e.type === "thinking_delta") {
          const delta = typeof e.delta === "string" ? e.delta : "";
          this.thinkingBuffers.set(
            idx,
            (this.thinkingBuffers.get(idx) ?? "") + delta,
          );
          // Stream the reasoning token so the thinking card is anchored at the
          // point reasoning STARTED — not when it ends. Some providers (e.g.
          // OpenAI Responses / gpt-5) stream the answer's text before the
          // reasoning item closes; without streaming, agent.thinking would be
          // assigned a later seq than the answer and render below it.
          const thinkId = this.thinkIds.get(idx);
          if (thinkId && delta.length > 0) {
            this.emitEvent({
              ts: Date.now(),
              kind: "agent.thinking.delta",
              payload: { thinkId, chunk: delta },
            });
          }
        } else if (e.type === "thinking_end") {
          const text =
            this.thinkingBuffers.get(idx) ??
            (typeof e.content === "string" ? e.content : "");
          const thinkId = this.thinkIds.get(idx);
          this.thinkingBuffers.delete(idx);
          this.thinkIds.delete(idx);
          if (text.trim().length > 0) {
            // Final authoritative thinking — carries thinkId so the app
            // finalizes the streamed card instead of appending a duplicate.
            this.emitEvent({
              ts: Date.now(),
              kind: "agent.thinking",
              payload: { text, ...(thinkId ? { thinkId } : {}) },
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
            // Structured tool result (e.g. askUserQuestion's {indices,answers})
            // for renderers that want more than the text. Best-effort.
            ...(isRecord(evt.result) && evt.result.details
              ? { details: evt.result.details }
              : {}),
          },
        });
        return;
      }

      default:
        return;
    }
  }
}

// ---------- helpers ---------------------------------------------------------

/** One `assistantMessageEvent` sub-frame (text/thinking streaming). */
interface PiAssistantEvent {
  type?: string;
  contentIndex?: number;
  delta?: unknown;
  content?: unknown;
}

/**
 * The handful of pi rpc frame fields the adapter actually consumes. Inbound
 * frames are untrusted JSON; nested payloads stay `unknown` and are narrowed at
 * the point of use. This is the minimal wire contract that lets us drop the
 * file-level `no-explicit-any` and confine `any` to the JSON.parse boundary
 * (see `wire.ts`).
 */
interface PiFrame {
  type?: string;
  // response frames
  command?: string;
  success?: boolean;
  data?: unknown;
  // extension_ui_request frames
  id?: unknown;
  method?: unknown;
  title?: unknown;
  message?: unknown;
  options?: unknown;
  placeholder?: unknown;
  prefill?: unknown;
  // message_update frames
  assistantMessageEvent?: PiAssistantEvent;
  // tool_execution_* frames
  toolCallId?: unknown;
  toolName?: unknown;
  args?: unknown;
  partialResult?: unknown;
  result?: unknown;
  isError?: unknown;
}

/** The `{provider, id, name}` triple carried in `session.meta` for a model. */
type MetaModel = { provider: string; id: string; name: string };

/**
 * Reduce a pi rpc [Model] object (see docs/rpc.md) to the `{provider,id,name}`
 * triple the app's `session.meta` carries. Returns null for a null/malformed
 * model so callers can render "no model yet".
 */
function normalizeModel(m: unknown): MetaModel | null {
  if (!m || typeof m !== "object") return null;
  const o = m as Record<string, unknown>;
  const provider = typeof o.provider === "string" ? o.provider : "";
  const id = typeof o.id === "string" ? o.id : "";
  if (!provider || !id) return null;
  const name = typeof o.name === "string" && o.name ? o.name : id;
  return { provider, id, name };
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
          isRecord(c) && typeof c.text === "string" ? c.text : "",
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
  return summarizeLine(text, `${name} ok`);
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
