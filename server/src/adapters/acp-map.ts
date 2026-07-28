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
}

export class AcpEventMapper {
  private textId?: string;
  private textBuf = "";
  private thinkId?: string;
  private thinkBuf = "";

  /** Tool-call ids we've already emitted a `tool.call.start` for. */
  private startedTools = new Set<string>();
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
        this.ensureToolStart(
          update.toolCallId,
          update.title || update.kind || "tool",
          update.kind ?? undefined,
          (update as { rawInput?: unknown }).rawInput,
        );
        this.applyToolContent(update.toolCallId, update);
        this.maybeEndTool(update.toolCallId, update.status, update);
        return;
      }

      case "tool_call_update": {
        this.ensureToolStart(
          update.toolCallId,
          update.title || "tool",
          update.kind ?? undefined,
          (update as { rawInput?: unknown }).rawInput,
        );
        this.applyToolContent(update.toolCallId, update);
        this.maybeEndTool(update.toolCallId, update.status, update);
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
    this.startedTools.clear();
    this.toolText.clear();
    this.seenMedia.clear();
    this.ingestedPayloads.clear();
  }

  // ---- internals ----------------------------------------------------------

  private ensureToolStart(id: string, name: string, kind: ToolKind | undefined, args: unknown): void {
    if (this.startedTools.has(id)) return;
    this.startedTools.add(id);
    this.emit("tool.call.start", {
      callId: id,
      name,
      args: args ?? {},
      risk: riskFromKind(kind),
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
    this.startedTools.delete(id);
  }

  private flushText(): void {
    if (this.textId && this.textBuf.length > 0) {
      this.emit("agent.message", { text: this.textBuf, msgId: this.textId });
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

function contentBlockText(block: unknown): string {
  if (block && typeof block === "object" && (block as { type?: unknown }).type === "text") {
    const t = (block as { text?: unknown }).text;
    if (typeof t === "string") return t;
  }
  return "";
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
