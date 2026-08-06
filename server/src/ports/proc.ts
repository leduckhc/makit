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
 * Read the whole-machine process table. Degrades to an empty table on a spawn
 * fault or non-zero exit — a caller reading the ancestor map treats "no procs"
 * as "attribution unknown", never as a crash.
 */
export async function readProcs(
  exec: Exec,
  nowMs: number,
  timeoutMs?: number,
): Promise<Map<number, ProcInfo>> {
  try {
    const { code, stdout } = await exec("ps", [...PS_ARGS], undefined, timeoutMs);
    if (code !== 0) return new Map();
    return parseProcs(stdout, nowMs);
  } catch {
    return new Map();
  }
}

/** Parse `lsof -Fpn` cwd output: `p<pid>` then `fcwd` then `n<path>`, pure. */
export function parseLsofCwds(stdout: string): Map<number, string> {
  const cwds = new Map<number, string>();
  let pid: number | undefined;
  for (const line of stdout.split("\n")) {
    if (line.length === 0) continue;
    const field = line[0];
    const value = line.slice(1);
    if (field === "p") pid = /^\d+$/.test(value) ? Number(value) : undefined;
    else if (field === "n" && pid !== undefined) cwds.set(pid, value);
    // `fcwd` (the descriptor marker) carries no data we keep.
  }
  return cwds;
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
): Promise<Map<number, string>> {
  if (pids.length === 0) return new Map();
  try {
    const { stdout } = await exec(
      "lsof",
      ["-a", "-d", "cwd", "-Fpn", "-p", pids.join(",")],
      undefined,
      timeoutMs,
    );
    return parseLsofCwds(stdout);
  } catch {
    return new Map();
  }
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
