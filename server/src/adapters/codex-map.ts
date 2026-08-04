/**
 * CodexEventMapper — pure translation from Codex **app-server** (v2) streaming
 * `ServerNotification`s into makit's normalized `AdapterEvent`s.
 *
 * app-server gives explicit item ids + item/started + item/completed, so unlike
 * the ACP mapper we key streams by `itemId` and finalize on `item/completed`
 * (no flush-on-switch heuristic needed). Server→client *requests* (approvals,
 * requestUserInput, elicitation) are handled by the adapter, not here.
 */

import type { AdapterEvent } from "./adapter.js";
import type { MediaDescriptor } from "../media/store.js";
import { summarizeLine } from "./summarize.js";
import { imageBlocksIn, type ImageBlock } from "./tool_media.js";

export interface CodexMapperHooks {
  emit: (e: AdapterEvent) => void;
  /** Agent-driven thread rename (`thread/name/updated`). */
  onTitle?: (title: string) => void;
  /**
   * Persist an image block carried by an MCP tool result and return its
   * descriptor (`null` = refused: bad mime / over cap). Injected rather than
   * imported so this mapper stays pure and testable — same seam as the ACP
   * mapper's hook. Absent = images are ignored.
   */
  putMedia?: (data: string, mime: string) => MediaDescriptor | null;
}

type Risk = "safe" | "risky" | "destructive";

export class CodexEventMapper {
  /** Tool-call item ids we've emitted a `tool.call.start` for. */
  private startedTools = new Set<string>();
  /** Media ids already announced, so an identical blob is announced once. */
  private seenMedia = new Set<string>();

  constructor(private readonly hooks: CodexMapperHooks) {}

  handle(method: string, params: any): void {
    switch (method) {
      case "item/agentMessage/delta":
        this.emit("agent.message.delta", { msgId: params?.itemId, chunk: params?.delta ?? "" });
        return;
      case "item/reasoning/textDelta":
        this.emit("agent.thinking.delta", { thinkId: params?.itemId, chunk: params?.delta ?? "" });
        return;
      case "item/commandExecution/outputDelta": {
        const chunk = typeof params?.delta === "string" ? params.delta : "";
        if (chunk) this.emit("tool.call.delta", { callId: params?.itemId, chunk });
        return;
      }
      case "item/started":
        this.onItemStarted(params?.item);
        return;
      case "item/completed":
        this.onItemCompleted(params?.item);
        return;
      case "thread/name/updated": {
        const name = params?.threadName;
        if (typeof name === "string" && name.trim()) this.hooks.onTitle?.(name.trim());
        return;
      }
      case "error": {
        this.emit("session.error", { message: turnErrorText(params?.error) });
        return;
      }
      default:
        return; // turn/*, plan/delta, token usage, warnings, etc. — ignored for now
    }
  }

  /** Reset per-turn tool bookkeeping (called by the adapter on turn end). */
  endTurn(): void {
    this.startedTools.clear();
  }

  // ---- items ---------------------------------------------------------------

  private onItemStarted(item: any): void {
    if (!item || typeof item !== "object") return;
    const start = this.toolStart(item);
    if (start) {
      this.startedTools.add(item.id);
      this.emit("tool.call.start", start);
    }
    // agentMessage / reasoning / plan: streamed via deltas + finalized on completed.
  }

  private onItemCompleted(item: any): void {
    if (!item || typeof item !== "object") return;
    switch (item.type) {
      case "agentMessage":
        this.emit("agent.message", { text: item.text ?? "", msgId: item.id });
        return;
      case "reasoning": {
        const src = Array.isArray(item.content) && item.content.length
          ? item.content
          : Array.isArray(item.summary)
            ? item.summary
            : typeof item.summary === "string"
              ? [item.summary]
              : [];
        const text = src.filter((s: unknown) => typeof s === "string").join("\n");
        if (text.trim()) this.emit("agent.thinking", { text, thinkId: item.id });
        return;
      }
      case "commandExecution":
      case "fileChange":
      case "mcpToolCall":
      case "dynamicToolCall":
      case "webSearch": {
        // Ensure a start was emitted even if item/started was skipped.
        if (!this.startedTools.has(item.id)) {
          const start = this.toolStart(item);
          if (start) this.emit("tool.call.start", start);
        }
        this.startedTools.delete(item.id);
        // Images ride along MCP tool results (a `read` of a PNG, a cua-driver
        // screenshot). Announce them before the terminal event so the
        // transcript order matches what happened.
        if (item.type === "mcpToolCall") this.ingestToolMedia(item.id, item.result);
        const { exitCode, output } = this.toolResult(item);
        this.emit("tool.call.end", {
          callId: item.id,
          exitCode,
          summary: summarizeLine(output),
          output,
        });
        return;
      }
      default:
        return; // userMessage, plan, contextCompaction, etc.
    }
  }

  private toolStart(item: any): Record<string, unknown> | undefined {
    switch (item.type) {
      case "commandExecution":
        return {
          callId: item.id,
          name: "bash",
          args: { command: item.command, cwd: item.cwd },
          risk: "risky" as Risk,
        };
      case "fileChange":
        return { callId: item.id, name: "apply_patch", args: { changes: item.changes }, risk: "risky" as Risk };
      case "mcpToolCall":
        return {
          callId: item.id,
          name: `${item.server}/${item.tool}`,
          args: item.arguments ?? {},
          risk: "safe" as Risk,
        };
      case "dynamicToolCall":
        return { callId: item.id, name: String(item.tool ?? "tool"), args: item.arguments ?? {}, risk: "safe" as Risk };
      case "webSearch":
        return { callId: item.id, name: "web_search", args: { query: item.query }, risk: "safe" as Risk };
      default:
        return undefined;
    }
  }

  private toolResult(item: any): { exitCode: number; output: string } {
    switch (item.type) {
      case "commandExecution": {
        const failed = item.status === "failed" || item.status === "declined";
        const exitCode = typeof item.exitCode === "number" ? item.exitCode : failed ? 1 : 0;
        return { exitCode, output: typeof item.aggregatedOutput === "string" ? item.aggregatedOutput : "" };
      }
      case "fileChange": {
        const failed = item.status === "failed" || item.status === "declined";
        return { exitCode: failed ? 1 : 0, output: fileChangeSummary(item.changes) };
      }
      case "mcpToolCall":
        return { exitCode: item.error ? 1 : 0, output: mcpResultText(item.result) || mcpErrorText(item.error) };
      case "dynamicToolCall":
        return { exitCode: item.success === false ? 1 : 0, output: dynamicToolText(item.contentItems) };
      case "webSearch":
        return { exitCode: 0, output: typeof item.query === "string" ? item.query : "" };
      default:
        return { exitCode: 0, output: "" };
    }
  }

  // ---- tool-result media (SPEC-22) -----------------------------------------

  /** Store every image block in `result` and emit one `agent.media` per new blob. */
  private ingestToolMedia(callId: string, result: unknown): void {
    if (!this.hooks.putMedia) return;
    for (const block of imageBlocksIn(result)) this.storeMedia(block, callId);
  }

  /**
   * Store `block` and announce it unless that exact blob was already announced.
   *
   * Dedup is by the store's content-addressed `mediaId` only. There is no
   * pre-store payload guard: app-server delivers `item/completed` once per item,
   * so a result is never re-scanned, and `putBase64` is idempotent for identical
   * bytes. (The ACP mapper does guard, because ACP re-sends `rawOutput`
   * cumulatively on every update.)
   */
  private storeMedia(block: ImageBlock, callId: string): void {
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
      callId,
    });
  }

  private emit(kind: AdapterEvent["kind"], payload: Record<string, unknown>): void {
    this.hooks.emit({ ts: Date.now(), kind, payload });
  }
}

// ---------- helpers ---------------------------------------------------------

function turnErrorText(error: unknown): string {
  if (typeof error === "string") return error;
  if (error && typeof error === "object") {
    const m = (error as { message?: unknown }).message;
    if (typeof m === "string") return m;
    try {
      return JSON.stringify(error);
    } catch {
      /* ignore */
    }
  }
  return "agent error";
}

function fileChangeSummary(changes: unknown): string {
  if (!Array.isArray(changes)) return "";
  const paths = changes
    .map((c) => (c && typeof c === "object" ? (c as { path?: unknown }).path : undefined))
    .filter((p): p is string => typeof p === "string");
  return paths.length ? paths.join("\n") : "(patch applied)";
}

function mcpResultText(result: unknown): string {
  if (!result || typeof result !== "object") return "";
  const content = (result as { content?: unknown }).content;
  if (!Array.isArray(content)) return "";
  return content
    .map((c) => (c && typeof c === "object" && typeof (c as any).text === "string" ? (c as any).text : ""))
    .filter(Boolean)
    .join("\n");
}

function mcpErrorText(error: unknown): string {
  if (!error) return "";
  if (typeof error === "string") return error;
  const m = (error as { message?: unknown }).message;
  return typeof m === "string" ? m : "tool error";
}

function dynamicToolText(items: unknown): string {
  if (!Array.isArray(items)) return "";
  return items
    .map((c) => (c && typeof c === "object" && typeof (c as any).text === "string" ? (c as any).text : ""))
    .filter(Boolean)
    .join("\n");
}
