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
 * (msgId/thinkId + delta + final) contract the app expects from PiAdapter.
 */

import type { SessionUpdate, ToolKind } from "@agentclientprotocol/sdk";
import type { AdapterEvent } from "./adapter.js";
import { newId } from "../protocol.js";

export interface AcpMapperHooks {
  emit: (e: AdapterEvent) => void;
  /** Agent-driven session rename (ACP `session_info_update.title`). */
  onTitle?: (title: string) => void;
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

  constructor(private readonly hooks: AcpMapperHooks) {}

  handle(update: SessionUpdate): void {
    switch (update.sessionUpdate) {
      case "agent_message_chunk": {
        this.flushThinking();
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
      summary: summarize(output),
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

function summarize(text: string): string {
  const firstLine =
    text
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l.length > 0) ?? "";
  if (!firstLine) return "ok";
  return firstLine.length > 120 ? `${firstLine.slice(0, 117)}…` : firstLine;
}
