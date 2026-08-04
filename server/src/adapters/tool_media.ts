/**
 * Image blocks reachable from a tool result, shared by the ACP and codex
 * app-server mappers (SPEC-22).
 *
 * Both harnesses hand back MCP tool results, and an MCP result may carry image
 * bytes (a `read` of a PNG, a `cua-driver` screenshot) alongside its text. The
 * scan is deliberately shape-tolerant: pi-acp puts the bytes in `rawOutput`
 * while normalized ACP `content[]` keeps only text, and codex nests the raw MCP
 * result under `item.result.content` — so callers pass whichever locations their
 * protocol uses and this module finds the blocks in any of them.
 */

/** An MCP/ACP image content block: base64 `data` + its `mimeType`. */
export interface ImageBlock {
  data: string;
  mimeType: string;
}

export function asImageBlock(v: unknown): ImageBlock | null {
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
export function imageBlocksIn(v: unknown): ImageBlock[] {
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
