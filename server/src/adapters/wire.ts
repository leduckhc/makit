/**
 * wire — the single JSON-parse boundary for the subprocess adapters. Inbound
 * agent frames are untrusted `unknown`; adapters narrow them with `isRecord`
 * (and small typed reads) at the top of their line handlers instead of
 * blanket-casting to `any`.
 */

/** True for a non-null object — i.e. a decoded JSON record. */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

/**
 * Parse one LF-delimited JSON line. Returns `undefined` for blank or malformed
 * input so callers can skip it rather than tear down the connection. This is
 * the ONE place a decoded frame crosses from `any` (JSON.parse) into `unknown`.
 */
export function parseJsonLine(line: string): unknown {
  if (!line.trim()) return undefined;
  try {
    return JSON.parse(line) as unknown;
  } catch {
    return undefined;
  }
}
