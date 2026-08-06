/**
 * proc.ts — the process half of a port scan: the whole-machine process table
 * and the per-pid working directory.
 *
 * Two reads, both best-effort:
 *  - `ps -axo pid=,ppid=,etime=,args=` → ppid (for the ancestor walk) + full
 *    argv (the row shows the command) + start time (uptime).
 *  - `lsof -a -d cwd -Fpn -p <csv>` → the cwd of a set of pids, in ONE call.
 *
 * This deliberately does NOT reuse `metrics/proc_table.ts`: that reader takes
 * `comm=` (no argv) and `time=` (cumulative CPU, not elapsed) and runs on the
 * 1 Hz metrics hot path. Widening its `ps` for a 4 s feature would tax the
 * dashboard's loop for nothing (spec §"What P1 reuses rather than rebuilds").
 * `rss` is not collected at all (spec D5: no memory story).
 */

import { realpathSync } from "node:fs";
import type { Exec } from "../metrics/proc_table.js";
import { log } from "../log.js";

export type { Exec } from "../metrics/proc_table.js";

const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = 3600;
const SECONDS_PER_DAY = 86_400;
const MS_PER_SECOND = 1000;

/** One process row. `startedAt` is absent when `etime` could not be parsed. */
export interface ProcInfo {
  pid: number;
  ppid: number;
  /** Full argv, exactly as `ps` printed it (spaces preserved). */
  command: string;
  /** Epoch ms the process started; absent, never 0, when `etime` was unparsable. */
  startedAt?: number;
}

/**
 * Parse a `ps -o etime=` field into elapsed seconds. Accepts the three shapes
 * `ps` emits: `mm:ss`, `hh:mm:ss`, `dd-hh:mm:ss`. Returns null for anything
 * else so the caller OMITS `startedAt` — a fabricated 0 renders as "up 56y".
 */
function parseEtimeSeconds(raw: string): number | null {
  let days = 0;
  let clock = raw;

  const dash = raw.indexOf("-");
  if (dash >= 0) {
    days = Number(raw.slice(0, dash));
    clock = raw.slice(dash + 1);
    if (!Number.isInteger(days) || days < 0) return null;
  }

  const parts = clock.split(":");
  if (parts.length < 2 || parts.length > 3) return null;
  if (!parts.every((p) => /^\d+$/.test(p))) return null;
  const values = parts.map(Number);

  const seconds =
    parts.length === 3
      ? values[0]! * SECONDS_PER_HOUR + values[1]! * SECONDS_PER_MINUTE + values[2]!
      : values[0]! * SECONDS_PER_MINUTE + values[1]!;

  return days * SECONDS_PER_DAY + seconds;
}

/**
 * Parse `ps -axo pid=,ppid=,etime=,args=` stdout into a table keyed by pid.
 *
 * Three leading whitespace-delimited fields (pid, ppid, etime) then the
 * remainder as `command` — argv legitimately contains spaces, so a naive
 * `split(/\s+/)` would truncate every command at its first argument. One
 * malformed line is skipped; the rest of the table is kept.
 */
export function parseProcs(stdout: string, nowMs: number): Map<number, ProcInfo> {
  const table = new Map<number, ProcInfo>();

  for (const line of stdout.split("\n")) {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/);
    if (!match) continue;
    const [, pidRaw, ppidRaw, etimeRaw, command] = match;
    const pid = Number(pidRaw);
    const ppid = Number(ppidRaw);

    const elapsed = parseEtimeSeconds(etimeRaw!);
    const info: ProcInfo = { pid, ppid, command: command! };
    if (elapsed !== null) info.startedAt = nowMs - elapsed * MS_PER_SECOND;
    table.set(pid, info);
  }

  return table;
}

/** The one `ps` invocation. Trailing `=` on each field suppresses headers. */
const PS_ARGS = ["-axo", "pid=,ppid=,etime=,args="] as const;

/**
 * Result of {@link readProcs}. `ok` is false when the `ps` command did not run
 * (spawn fault, timeout, or a non-zero exit): the scanner must publish
 * `scanOk:false` rather than claim a successful scan over an empty table (D7).
 */
export interface ProcsResult {
  ok: boolean;
  procs: Map<number, ProcInfo>;
  /** One-line reason when `ok` is false, for the glyph's tooltip. */
  error?: string;
}

/**
 * Read the whole-machine process table. Degrades to an EMPTY table with
 * `ok:false` on a spawn fault or non-zero exit — the caller then publishes
 * `scanOk:false` with the reason rather than pretending the machine had no
 * processes. Unlike lsof, `ps` does not warn on stderr, so a non-zero exit is a
 * real failure.
 */
export async function readProcs(
  exec: Exec,
  nowMs: number,
  timeoutMs?: number,
): Promise<ProcsResult> {
  try {
    const { code, stdout, stderr } = await exec("ps", [...PS_ARGS], undefined, timeoutMs);
    if (code !== 0) {
      const reason = firstLine(stderr) || `exit ${code}`;
      log.debug(`[ports] ps failed: ${reason}`);
      return { ok: false, procs: new Map(), error: `ps failed: ${reason}` };
    }
    return { ok: true, procs: parseProcs(stdout, nowMs) };
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    log.debug(`[ports] ps failed: ${reason}`);
    return { ok: false, procs: new Map(), error: `ps failed: ${reason}` };
  }
}

/** Parse `lsof -Fpn` cwd output: `p<pid>` then `fcwd` then `n<path>`, pure.
 *
 * The `fcwd` marker is load-bearing: `lsof -d cwd` requests only cwd file
 * descriptors, but some versions emit annotation `n` lines (e.g.
 * `n(readlink: Permission denied)`) that are not a path. We store an `n` only
 * when the immediately preceding `f` record for this pid was `cwd`, so an
 * annotation line cannot be mistaken for a process's working directory.
 */
export function parseLsofCwds(stdout: string): Map<number, string> {
  const cwds = new Map<number, string>();
  let pid: number | undefined;
  let atCwd = false; // true only between an `fcwd` record and its `n` path
  for (const line of stdout.split("\n")) {
    if (line.length === 0) continue;
    const field = line[0];
    const value = line.slice(1);
    if (field === "p") {
      pid = /^\d+$/.test(value) ? Number(value) : undefined;
      atCwd = false;
    } else if (field === "f") {
      atCwd = value === "cwd";
    } else if (field === "n" && pid !== undefined && atCwd) {
      cwds.set(pid, value);
      atCwd = false; // consume: a trailing annotation `n` is not a second cwd
    }
  }
  return cwds;
}

/**
 * Result of {@link readCwds}. `ok` is false only when the command was
 * UNAVAILABLE (spawn fault / timeout / non-zero exit with no output); a
 * non-zero exit that still produced records is fine — see the note in
 * {@link readCwds}.
 */
export interface CwdsResult {
  ok: boolean;
  cwds: Map<number, string>;
  /** One-line reason when `ok` is false, for the glyph's tooltip. */
  error?: string;
}

/**
 * Read the cwd of each pid in one `lsof` call.
 *
 * An empty `pids` issues NO command and returns an empty map: `lsof -p` with an
 * empty argument lists EVERY open file on the machine — a multi-second dump that
 * would also mis-attribute unrelated cwds. This guard is load-bearing, not a
 * micro-optimisation.
 */
export async function readCwds(
  exec: Exec,
  pids: number[],
  timeoutMs?: number,
): Promise<CwdsResult> {
  if (pids.length === 0) return { ok: true, cwds: new Map() };
  try {
    const { code, stdout, stderr } = await exec(
      "lsof",
      ["-a", "-d", "cwd", "-Fpn", "-p", pids.join(",")],
      undefined,
      timeoutMs,
    );
    // Unlike `readProcs`, a mere non-zero exit is NOT a failure here: lsof exits
    // 1 while routinely warning about pids it could not fully stat, yet still
    // prints every cwd it did see. Only an UNAVAILABLE command (non-zero exit
    // with no output at all — a spawn fault or timeout via `git.run`) is a
    // failure. Do not "fix" this to fail on `code !== 0`.
    if (code !== 0 && stdout.trim().length === 0) {
      const reason = firstLine(stderr) || `exit ${code}`;
      log.debug(`[ports] cwd lsof failed: ${reason}`);
      return { ok: false, cwds: new Map(), error: `cwd lsof failed: ${reason}` };
    }
    return { ok: true, cwds: parseLsofCwds(stdout) };
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    log.debug(`[ports] cwd lsof failed: ${reason}`);
    return { ok: false, cwds: new Map(), error: `cwd lsof failed: ${reason}` };
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

/**
 * A memoised `realpath` resolver. macOS aliases `/tmp` and `/var` to
 * `/private/...`, so a process's cwd and a worktree path can name the same
 * directory in two spellings; attribution must compare the resolved forms.
 * Resolving is a syscall, so it is cached per distinct input for the life of one
 * scan. An unresolvable path (deleted, permission) falls back to the input — a
 * best-effort comparison beats a throw.
 */
export function createRealpathResolver(
  realpath: (p: string) => string = realpathSync,
): (path: string) => string {
  const cache = new Map<string, string>();
  return (path: string): string => {
    const cached = cache.get(path);
    if (cached !== undefined) return cached;
    let resolved: string;
    try {
      resolved = realpath(path);
    } catch {
      resolved = path;
    }
    cache.set(path, resolved);
    return resolved;
  };
}
