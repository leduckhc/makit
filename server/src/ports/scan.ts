/**
 * scan.ts — the listener half of a port scan: `lsof -nP -iTCP -sTCP:LISTEN`.
 *
 * `lsof -F` emits one field per line, field type as the first character. We ask
 * for `-FpPnu` (pid, protocol, name, uid) but lsof ALSO emits an `f`
 * (file-descriptor) record before every file's fields, and repeats `P`/`n` per
 * fd — so real output interleaves records we must skip WITHOUT losing the
 * process-level `p`/`u` state that a run of names belongs to:
 *
 *     p669      ← process: pid, applies to every name until the next `p`
 *     u501      ← process: uid
 *     f10       ← file: a descriptor (ignored, but resets nothing we own)
 *     PTCP      ← file: protocol
 *     n*:61170  ← file: the bind name → one listener
 *     f11 / PTCP / n*:61170   ← the SAME endpoint over a second fd (dual-stack)
 *
 * The parser is a tiny state machine: `p`/`u` set the current process; each `n`
 * emits a listener against that process. A malformed name is skipped, never
 * thrown — lsof output varies by version and a single odd row must not blind the
 * whole scan (spec risk: "lsof -F output varies by version").
 */

// The injected command runner is shared across the whole scan (lsof + ps): one
// `Exec` seam, defined once in the metrics subsystem, so tests supply a literal
// and never spawn a subprocess. Re-exported so siblings import it from here.
import type { Exec } from "../metrics/proc_table.js";
export type { Exec } from "../metrics/proc_table.js";

/** One listening TCP socket as `lsof` reports it, before any attribution. */
export interface Listener {
  pid: number;
  /** Owning uid, or undefined when lsof omitted the `u` record. */
  uid: number | undefined;
  /** Bind address verbatim: `127.0.0.1`, `0.0.0.0`, `*`, `::1`, `::`. */
  address: string;
  port: number;
}

export interface ScanResult {
  /**
   * True when the `lsof` command ran (spec D7 `scanOk`). False ONLY on a spawn
   * fault — a non-zero exit is NOT a failure here because lsof exits 1 while
   * routinely warning about processes it could not fully stat, and still prints
   * every listener it did see.
   */
  ok: boolean;
  listeners: Listener[];
  /** One-line reason when `ok` is false, for the glyph's tooltip. */
  error?: string;
}

/** The one `lsof` invocation. `-FpPnu` selects pid, protocol, name, uid fields. */
const LSOF_ARGS = ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpPnu"] as const;

/**
 * Split an `lsof` name (`address:port`) into parts. Handles the IPv6 bracket
 * form (`[::1]:9787`) and the wildcard (`*:5173`); returns null when there is no
 * colon or the port is not numeric, so the caller drops the row.
 */
function parseName(name: string): { address: string; port: number } | null {
  const colon = name.lastIndexOf(":");
  if (colon < 0) return null;
  const portRaw = name.slice(colon + 1);
  if (!/^\d+$/.test(portRaw)) return null;
  let address = name.slice(0, colon);
  // IPv6 is bracketed to disambiguate its own colons: `[::1]:9787`.
  if (address.startsWith("[") && address.endsWith("]")) address = address.slice(1, -1);
  return { address, port: Number(portRaw) };
}

/**
 * Parse `lsof -F` stdout into listeners. Pure: no I/O, no throw.
 *
 * Identical (pid, address, port) tuples are collapsed — a dual-stack process
 * answers on one endpoint over two file descriptors, and the snapshot key
 * (`<pid>:<address>:<port>`) must be unique.
 */
export function parseLsofListeners(stdout: string): Listener[] {
  const byKey = new Map<string, Listener>();
  let pid: number | undefined;
  let uid: number | undefined;

  for (const line of stdout.split("\n")) {
    if (line.length === 0) continue;
    const field = line[0];
    const value = line.slice(1);
    switch (field) {
      case "p": {
        pid = /^\d+$/.test(value) ? Number(value) : undefined;
        uid = undefined; // a new process clears the previous one's uid
        break;
      }
      case "u": {
        uid = /^\d+$/.test(value) ? Number(value) : undefined;
        break;
      }
      case "n": {
        if (pid === undefined) break; // a name with no owning process is unusable
        const parsed = parseName(value);
        if (!parsed) break;
        const key = `${pid}:${parsed.address}:${parsed.port}`;
        if (!byKey.has(key)) {
          byKey.set(key, { pid, uid, address: parsed.address, port: parsed.port });
        }
        break;
      }
      default:
        // `f` (fd), `P` (protocol) and any field we did not request are ignored;
        // they never disturb the current `p`/`u` state.
        break;
    }
  }

  return [...byKey.values()];
}

/**
 * Run `lsof` and parse its listeners. Degrades to `{ok:false}` with a one-line
 * reason when the command is UNAVAILABLE — a spawn fault or a timeout, which the
 * shared runner (`git.run`) surfaces NOT as a rejection but as a resolved
 * `{code:127, stdout:""}`. A non-zero exit that still produced output is parsed
 * normally (lsof exits 1 while routinely warning; see {@link ScanResult.ok}).
 */
export async function listListeners(exec: Exec, timeoutMs?: number): Promise<ScanResult> {
  try {
    const { code, stdout, stderr } = await exec("lsof", [...LSOF_ARGS], undefined, timeoutMs);
    // A non-zero exit with NO output is an unavailable/timed-out command, not a
    // warning — treat it as a failure so the caller keeps its last good ports
    // instead of blanking them under a false `scanOk:true`.
    if (code !== 0 && stdout.trim().length === 0) {
      const reason = firstLine(stderr) || `exit ${code}`;
      return { ok: false, listeners: [], error: `lsof failed: ${reason}` };
    }
    return { ok: true, listeners: parseLsofListeners(stdout) };
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    return { ok: false, listeners: [], error: `lsof failed: ${reason}` };
  }
}

/** The first non-empty line of a command's stderr, trimmed — the tooltip is one line. */
function firstLine(text: string): string {
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.length > 0) return trimmed;
  }
  return "";
}
