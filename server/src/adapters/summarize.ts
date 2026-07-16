/**
 * summarize — the ONE first-non-empty-line extractor used to build the
 * collapsed tool-card summary. Previously copy-pasted into acp-map.ts,
 * codex-map.ts, and pi.ts (each with a slightly different fallback).
 */

/** Max characters kept in a collapsed one-line summary before ellipsis. */
const SUMMARY_MAX = 120;

/** First non-empty, trimmed line of [text] (or "" when there is none). */
export function firstNonEmptyLine(text: string): string {
  return (
    text
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l.length > 0) ?? ""
  );
}

/**
 * Collapse [text] to a single summary line, truncated with an ellipsis.
 * Returns [fallback] when there is no non-empty line.
 */
export function summarizeLine(text: string, fallback = "ok"): string {
  const first = firstNonEmptyLine(text);
  if (!first) return fallback;
  return first.length > SUMMARY_MAX ? `${first.slice(0, SUMMARY_MAX - 3)}…` : first;
}
