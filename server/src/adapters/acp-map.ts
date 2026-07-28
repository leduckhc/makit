/**
 * AcpEventMapper — pure translation from ACP `session/update` notifications
 * (agentclientprotocol v1) into makit's normalized `AdapterEvent`s.
 *
 * Kept free of I/O so it can be unit-tested in isolation. `AcpAdapter` owns the
 * subprocess + JSON-RPC connection and feeds updates here.
 *
 * Streaming model: ACP streams `agent_message_chunk` / `agent_thought_chunk`
 * without explicit start/end markers, so we buffer per "run" and finalize on
 * switch (text↔thought), on any tool call, or at turn end. This mirrors the
 * (msgId/thinkId + delta + final) contract the app expects from the pi adapter.
 */

import type { SessionUpdate, ToolKind } from "@agentclientprotocol/sdk";
import type { AdapterEvent } from "./adapter.js";
import type { MediaDescriptor } from "../media/store.js";
import { summarizeLine } from "./summarize.js";
import { newId } from "../protocol.js";

export interface AcpMapperHooks {
  emit: (e: AdapterEvent) => void;
  /** Agent-driven session rename (ACP `session_info_update.title`). */
  onTitle?: (title: string) => void;
  /**
   * Persist an image payload (SPEC-22) and return its descriptor, or `null`
   * when it is refused (disallowed mime, over the size cap, malformed base64).
   * Injected so this module stays I/O-free and unit-testable; the adapter wires
   * it to the content-addressed {@link MediaStore}. Synchronous on purpose: the
   * blob must be durable *before* the `agent.media` event that references it.
   */
  putMedia?: (data: string, mime: string) => MediaDescriptor | null;
  /**
   * Rewrite markdown image references in a finalized agent message, ingesting
   * any local files they point at (SPEC-22 phase 1b: agents commonly write a
   * file and then show it with `![](\/abs\/path.png)`, which the phone cannot
   * resolve). Injected for the same reason as {@link putMedia} — it touches the
   * filesystem. Applied only to the final message, never to streamed deltas.
   */
  rewriteMedia?: (text: string) => string;
}

export class AcpEventMapper {
  private textId?: string;
  private textBuf = "";
  private thinkId?: string;
  private thinkBuf = "";

  /**
   * Accumulated per-tool state. ACP agents (pi-acp) stream a tool call as a
   * `tool_call` with empty `rawInput` followed by several `tool_call_update`s
   * that progressively fill in the arguments (path/pattern) or, for bash, the
   * command in `title`. We therefore DEFER `tool.call.start` until the args are
   * ready (status `in_progress`/`completed`/`failed`, or the first output),
   * accumulating the best title/kind/rawInput seen so far. The app sets a tool
   * row's args once at start, so emitting too early (empty args) is what made
   * `read`/`grep`/`ls` render with no target and bash show "Ran bash".
   */
  private tools = new Map<
    string,
    { title: string; kind?: ToolKind; rawInput: unknown; started: boolean; suppressed?: boolean }
  >();
  /** Last cumulative output text seen per tool call (to diff into deltas). */
  private toolText = new Map<string, string>();
  /** mediaIds already announced this turn (updates re-send cumulative output). */
  private seenMedia = new Set<string>();
  /**
   * Cheap identity of image payloads already ingested this turn, so a
   * cumulative `tool_call_update` that re-sends the same base64 is not decoded
   * and re-hashed again. Keyed on call + length + a short prefix rather than a
   * real digest: colliding would require the same call to carry two images of
   * identical length sharing their first 64 base64 chars.
   */
  private ingestedPayloads = new Set<string>();

  constructor(private readonly hooks: AcpMapperHooks) {}

  handle(update: SessionUpdate): void {
    switch (update.sessionUpdate) {
      case "agent_message_chunk": {
        this.flushThinking();
        this.ingestMedia(update.content);
        const chunk = contentBlockText(update.content);
        if (!chunk) return;
        if (!this.textId) {
          this.textId = newId("am");
          this.textBuf = "";
        }
        this.textBuf += chunk;
        this.emit("agent.message.delta", { msgId: this.textId, chunk });
        return;
      }

      case "agent_thought_chunk": {
        this.flushText();
        const chunk = contentBlockText(update.content);
        if (!chunk) return;
        if (!this.thinkId) {
          this.thinkId = newId("th");
          this.thinkBuf = "";
        }
        this.thinkBuf += chunk;
        this.emit("agent.thinking.delta", { thinkId: this.thinkId, chunk });
        return;
      }

      case "user_message_chunk": {
        // Only seen during session/load history replay.
        this.flushAll();
        const text = contentBlockText(update.content);
        if (text) this.emit("user.message", { text });
        return;
      }

      case "tool_call": {
        this.flushAll();
        this.trackTool(update);
        return;
      }

      case "tool_call_update": {
        this.trackTool(update);
        return;
      }

      case "available_commands_update": {
        const commands = (update.availableCommands ?? []).map((c) => ({
          name: c.name,
          description: c.description ?? "",
          source: "command",
        }));
        this.emit("session.commands", { commands });
        return;
      }

      case "session_info_update": {
        const title = (update as { title?: unknown }).title;
        if (typeof title === "string" && title.trim()) this.hooks.onTitle?.(title.trim());
        return;
      }

      // plan / plan_update / plan_removed / current_mode_update /
      // config_option_update / usage_update: no makit event yet — ignore.
      default:
        return;
    }
  }

  /** Finalize any buffered text/thinking at the end of an agent turn. */
  endTurn(): void {
    this.flushAll();
    // A tool still tracked here never reported `completed`/`failed` (an aborted
    // or refused turn). Surface the ones that got as far as real args, but always
    // CLOSE them: a `tool.call.start` with no matching end leaves the row
    // spinning forever. A tool still waiting on its args never ran, so showing
    // it as "Read (no path) — failed" would be noise; drop it instead.
    for (const [id, t] of [...this.tools]) {
      if (!t.started && !hasUsableArgs(t)) continue;
      this.ensureToolStart(id);
      if (this.tools.get(id)?.suppressed) continue;
      const output = this.toolText.get(id) ?? "";
      this.emit("tool.call.end", { callId: id, exitCode: 1, summary: summarizeLine(output), output });
    }
    this.tools.clear();
    this.toolText.clear();
    this.seenMedia.clear();
    this.ingestedPayloads.clear();
  }

  // ---- internals ----------------------------------------------------------

  /**
   * Merge a `tool_call`/`tool_call_update` into the accumulated per-tool state,
   * then decide whether to emit `tool.call.start` yet. pi-acp fills args over
   * several updates, so we keep the LATEST non-empty title/kind/rawInput and
   * only start once the args are ready (status advanced past `pending`, or the
   * first output arrives) — after which content deltas and completion apply.
   */
  private trackTool(update: Extract<SessionUpdate, { sessionUpdate: "tool_call" | "tool_call_update" }>): void {
    const id = update.toolCallId;
    const cur = this.tools.get(id) ?? { title: "", kind: undefined as ToolKind | undefined, rawInput: undefined as unknown, started: false };
    const title = (update as { title?: unknown }).title;
    // Trim: the title becomes the tool `name` the app's renderer registry keys
    // on, and a padded name matches nothing (falls back to the generic body).
    if (typeof title === "string" && title.trim()) cur.title = title.trim();
    const kind = (update as { kind?: ToolKind }).kind;
    if (kind) cur.kind = kind;
    const raw = (update as { rawInput?: unknown }).rawInput;
    if (raw && typeof raw === "object" && Object.keys(raw as object).length > 0) cur.rawInput = raw;
    this.tools.set(id, cur);

    const status = update.status;
    // Start once the args are USABLE, not merely once the tool starts running:
    // pi-acp happens to finish streaming `rawInput` before `in_progress`, but
    // that is emitter ordering, not an ACP guarantee. Requiring args keeps the
    // "Read (no path)" bug fixed for agents that flip to `in_progress` first.
    // A terminal status or real output always starts it, so nothing is dropped.
    const terminal = status === "completed" || status === "failed";
    const argsReady = terminal || hasToolContent(update) || (status === "in_progress" && hasUsableArgs(cur));
    if (argsReady) this.ensureToolStart(id);
    if (!cur.started) return;
    if (cur.suppressed) {
      // Nothing was started for this call, so emitting deltas/end would be
      // orphan events. Just release its state once the call finishes.
      if (terminal) {
        this.toolText.delete(id);
        this.tools.delete(id);
      }
      return;
    }
    this.applyToolContent(id, update);
    this.maybeEndTool(id, status, update);
  }

  /** Emit `tool.call.start` from the accumulated state, exactly once per tool. */
  private ensureToolStart(id: string): void {
    const t = this.tools.get(id);
    if (!t || t.started) return;
    t.started = true;
    const { name, args } = canonicalizeTool(t.title, t.kind, t.rawInput);
    // `ask_user` never renders as a tool row: pi-acp emits the tool call AND a
    // separate permission request carrying the question, which the app shows as
    // an inline ask card (SPEC-25). A row would duplicate that card. Matched
    // case-insensitively, like the app's own renderer lookup.
    if (name.toLowerCase() === "ask_user") {
      t.suppressed = true;
      return;
    }
    this.emit("tool.call.start", {
      callId: id,
      name,
      args,
      risk: riskFromKind(t.kind),
    });
  }

  /** Emit a `tool.call.delta` for any new output text on this update. */
  private applyToolContent(id: string, update: SessionUpdate): void {
    // Images ride along tool results (a `read` of a PNG, an MCP screenshot).
    // Announce them before any terminal event so the transcript order matches
    // what happened.
    this.ingestToolMedia(id, update);
    // Some ACP adapters stream bash output as an already-computed delta in `_meta`.
    const metaDelta = terminalOutput(update);
    if (metaDelta) {
      this.emit("tool.call.delta", { callId: id, chunk: metaDelta });
      this.toolText.set(id, (this.toolText.get(id) ?? "") + metaDelta);
      return;
    }
    const full = toolContentText((update as { content?: unknown }).content);
    if (!full) return;
    const prev = this.toolText.get(id) ?? "";
    const delta = full.startsWith(prev) ? full.slice(prev.length) : full;
    if (delta) this.emit("tool.call.delta", { callId: id, chunk: delta });
    this.toolText.set(id, full);
  }

  private maybeEndTool(id: string, status: unknown, update: SessionUpdate): void {
    if (status !== "completed" && status !== "failed") return;
    const output = this.toolText.get(id) ?? "";
    const exitCode = status === "failed" ? 1 : terminalExitCode(update) ?? 0;
    this.emit("tool.call.end", {
      callId: id,
      exitCode,
      summary: summarizeLine(output),
      output,
    });
    this.toolText.delete(id);
    this.tools.delete(id);
  }

  private flushText(): void {
    if (this.textId && this.textBuf.length > 0) {
      const text = this.hooks.rewriteMedia?.(this.textBuf) ?? this.textBuf;
      this.emit("agent.message", { text, msgId: this.textId });
    }
    this.textId = undefined;
    this.textBuf = "";
  }

  /**
   * Store every image block attached to a tool update and emit one
   * `agent.media` per new blob.
   *
   * Both locations are scanned because pi-acp puts the bytes in **`rawOutput`**
   * (the raw MCP tool result) while the normalized ACP `content[]` keeps only a
   * text summary — verified against a pi-acp 0.0.32 capture. Other ACP agents
   * may do the reverse, so neither location is assumed.
   */
  private ingestToolMedia(callId: string, update: SessionUpdate): void {
    if (!this.hooks.putMedia) return;
    const u = update as { content?: unknown; rawOutput?: { content?: unknown } };
    for (const block of [...imageBlocksIn(u.content), ...imageBlocksIn(u.rawOutput?.content)]) {
      this.storeMedia(block, callId);
    }
  }

  /** Same, for an image carried directly as an agent-message content block. */
  private ingestMedia(block: unknown): void {
    if (!this.hooks.putMedia) return;
    for (const image of imageBlocksIn(block)) this.storeMedia(image);
  }

  private storeMedia(block: ImageBlock, callId?: string): void {
    const key = `${callId ?? ""}:${block.data.length}:${block.data.slice(0, 64)}`;
    if (this.ingestedPayloads.has(key)) return;
    this.ingestedPayloads.add(key);
    const stored = this.hooks.putMedia?.(block.data, block.mimeType);
    // null = refused (bad mime / over cap / malformed). Drop it silently: the
    // tool's text result still lands, so the turn is never blocked by media.
    if (!stored) return;
    if (this.seenMedia.has(stored.mediaId)) return;
    this.seenMedia.add(stored.mediaId);
    this.emit("agent.media", {
      mediaId: stored.mediaId,
      mime: stored.mime,
      kind: "image",
      sizeBytes: stored.sizeBytes,
      ...(callId ? { callId } : {}),
    });
  }

  private flushThinking(): void {
    if (this.thinkId && this.thinkBuf.trim().length > 0) {
      this.emit("agent.thinking", { text: this.thinkBuf, thinkId: this.thinkId });
    }
    this.thinkId = undefined;
    this.thinkBuf = "";
  }

  private flushAll(): void {
    this.flushThinking();
    this.flushText();
  }

  private emit(kind: AdapterEvent["kind"], payload: Record<string, unknown>): void {
    this.hooks.emit({ ts: Date.now(), kind, payload });
  }
}

// ---------- helpers ---------------------------------------------------------

/** An MCP/ACP image content block: base64 `data` + its `mimeType`. */
interface ImageBlock {
  data: string;
  mimeType: string;
}

function asImageBlock(v: unknown): ImageBlock | null {
  if (!v || typeof v !== "object") return null;
  const b = v as { type?: unknown; data?: unknown; mimeType?: unknown };
  if (b.type !== "image") return null;
  if (typeof b.data !== "string" || typeof b.mimeType !== "string") return null;
  return { data: b.data, mimeType: b.mimeType };
}

/**
 * Every image block reachable from `v`, which may be a single content block, a
 * `ContentBlock[]`, or an ACP `ToolCallContent[]` (whose items wrap the real
 * block under `.content`).
 */
function imageBlocksIn(v: unknown): ImageBlock[] {
  if (Array.isArray(v)) return v.flatMap(imageBlocksIn);
  const direct = asImageBlock(v);
  if (direct) return [direct];
  if (v && typeof v === "object" && "content" in v) {
    const inner = (v as { content?: unknown }).content;
    // Guard against self-reference; only descend into a different value.
    if (inner !== v) return imageBlocksIn(inner);
  }
  return [];
}

/**
 * Derive the makit tool `name` + `args` the app's renderer registry keys on
 * from an ACP tool call. The app matches renderers by canonical name (`bash`,
 * `read`, `edit`, `grep`, …); ACP identifies tools by `kind` + a human `title`
 * instead. Only `execute` needs remapping: ACP execute tools are shell commands
 * that must render via the `bash` renderer (terminal icon + `Ran <cmd>`), and
 * some agents (pi-acp) carry the command in `title` rather than `rawInput`.
 * Every other kind already arrives with a canonical tool name in `title`
 * (read/edit/write/grep/…), so it is passed through unchanged.
 *
 * NOTE: that pass-through assumes an agent whose titles ARE tool names, which is
 * true of pi-acp. An agent that titles calls in prose ("Read package.json")
 * matches no renderer and falls back to the generic args/output body — degraded,
 * not broken. Map such an agent's `kind`s here when one ships.
 */
function canonicalizeTool(
  title: string,
  kind: ToolKind | undefined,
  rawInput: unknown,
): { name: string; args: Record<string, unknown> } {
  const args: Record<string, unknown> =
    rawInput && typeof rawInput === "object" && !Array.isArray(rawInput) ? { ...(rawInput as Record<string, unknown>) } : {};
  if (kind === "execute") {
    if (typeof args.command !== "string" || !args.command.trim()) {
      const cmd = extractCommand(rawInput) ?? (title.trim() ? title : undefined);
      if (cmd) args.command = cmd;
    }
    return { name: "bash", args };
  }
  return { name: title || kind || "tool", args };
}

/** Pull a shell command out of an ACP `rawInput` object, if present. */
function extractCommand(rawInput: unknown): string | undefined {
  if (!rawInput || typeof rawInput !== "object") return undefined;
  const r = rawInput as Record<string, unknown>;
  const isNonBlank = (v: unknown): v is string => typeof v === "string" && v.trim().length > 0;
  if (isNonBlank(r.command)) return r.command;
  if (isNonBlank(r.cmd)) return r.cmd;
  return undefined;
}

function contentBlockText(block: unknown): string {
  if (block && typeof block === "object" && (block as { type?: unknown }).type === "text") {
    const t = (block as { text?: unknown }).text;
    if (typeof t === "string") return t;
  }
  return "";
}

/** True when this update carries renderable tool output (terminal or content). */
function hasToolContent(update: SessionUpdate): boolean {
  return terminalOutput(update) !== undefined || toolContentText((update as { content?: unknown }).content) !== "";
}

/**
 * True once we have something worth putting in a tool row's args: any streamed
 * `rawInput`, or — for an `execute` tool, whose command pi-acp carries in the
 * title — a non-blank title.
 */
function hasUsableArgs(t: { title: string; kind?: ToolKind; rawInput: unknown }): boolean {
  const raw = t.rawInput;
  if (raw && typeof raw === "object" && Object.keys(raw as object).length > 0) return true;
  return t.kind === "execute" && t.title.trim().length > 0;
}

/** Extract human-readable text from a ToolCallContent[] (text + diff blocks). */
function toolContentText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const item of content) {
    if (!item || typeof item !== "object") continue;
    const type = (item as { type?: unknown }).type;
    if (type === "content") {
      parts.push(contentBlockText((item as { content?: unknown }).content));
    } else if (type === "diff") {
      const d = item as { path?: unknown; newText?: unknown };
      const path = typeof d.path === "string" ? d.path : "";
      const newText = typeof d.newText === "string" ? d.newText : "";
      parts.push(path ? `${path}\n${newText}` : newText);
    }
    // "terminal" content carries no inline text — output arrives via _meta.
  }
  return parts.filter(Boolean).join("\n");
}

function terminalMeta(update: SessionUpdate): Record<string, any> | undefined {
  const meta = (update as { _meta?: unknown })._meta;
  return meta && typeof meta === "object" ? (meta as Record<string, any>) : undefined;
}

/** ACP adapter convention: `_meta.terminal_output.data` is an incremental delta. */
function terminalOutput(update: SessionUpdate): string | undefined {
  const data = terminalMeta(update)?.terminal_output?.data;
  return typeof data === "string" && data.length > 0 ? data : undefined;
}

function terminalExitCode(update: SessionUpdate): number | undefined {
  const code = terminalMeta(update)?.terminal_exit?.exit_code;
  return typeof code === "number" ? code : undefined;
}

function riskFromKind(kind: ToolKind | undefined): "safe" | "risky" | "destructive" {
  switch (kind) {
    case "delete":
      return "destructive";
    case "edit":
    case "move":
    case "execute":
      return "risky";
    default:
      // read, search, fetch, think, switch_mode, other, undefined
      return "safe";
  }
}
