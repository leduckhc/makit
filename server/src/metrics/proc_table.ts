/**
 * proc_table.ts — one `ps` snapshot of every process, parsed into a table.
 *
 * The metrics collector runs this once per tick (1 Hz while watched). A single
 * `ps -axo …` covers the whole machine; the ppid index and per-agent tree sums
 * are built downstream (see tree.ts). Everything here is best-effort: a process
 * name with spaces, a platform-specific `time=` shape, or one malformed line
 * must never throw — a metrics gap is acceptable, a crashed sampler is not.
 *
 * Platform notes that make or break correctness:
 *  - `rss` is KiB on both macOS and Linux → bytes = KiB * 1024.
 *  - `time=` is the most divergent field. We accept every shape observed:
 *      mm:ss  ·  mm:ss.cc  ·  hh:mm:ss  ·  dd-hh:mm:ss
 *    A wrong parse here corrupts every CPU number on the dashboard.
 */

const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = 3600;
const SECONDS_PER_DAY = 86_400;
const KIB = 1024;

/** The one `ps` invocation. Trailing `=` on each field suppresses headers. */
const PS_ARGS = ["-axo", "pid=,ppid=,rss=,time=,comm="] as const;

/** A single process row. `cpuSeconds` is cumulative CPU time (a float). */
export interface ProcRow {
  pid: number;
  ppid: number;
  rssBytes: number;
  cpuSeconds: number;
  comm: string;
}

/**
 * Injected command runner. Matches `run` in `git.ts` so production passes it
 * directly; tests supply a stub and never spawn a process.
 */
export type Exec = (
  cmd: string,
  args: string[],
  cwd?: string,
  timeoutMs?: number,
) => Promise<{ code: number; stdout: string; stderr: string }>;

/**
 * Parse a cumulative CPU-time field into seconds. Accepts every `ps -o time=`
 * shape seen on macOS and Linux:
 *   `mm:ss`, `mm:ss.cc`, `hh:mm:ss`, `dd-hh:mm:ss`.
 * Returns null for anything else so the caller can skip the row.
 */
function parseCpuSeconds(raw: string): number | null {
  let days = 0;
  let clock = raw;

  const dash = raw.indexOf("-");
  if (dash >= 0) {
    days = Number(raw.slice(0, dash));
    clock = raw.slice(dash + 1);
    if (!Number.isFinite(days) || days < 0) return null;
  }

  const parts = clock.split(":");
  if (parts.length < 2 || parts.length > 3) return null;

  const values = parts.map(Number);
  if (values.some((n) => !Number.isFinite(n) || n < 0)) return null;

  // Fractional seconds (the `.cc` suffix) fall out of Number() naturally.
  const seconds =
    parts.length === 3
      ? values[0] * SECONDS_PER_HOUR + values[1] * SECONDS_PER_MINUTE + values[2]
      : values[0] * SECONDS_PER_MINUTE + values[1];

  return days * SECONDS_PER_DAY + seconds;
}

/** Parse a non-negative integer field; null when malformed. */
function parseCount(raw: string): number | null {
  if (!/^\d+$/.test(raw)) return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

/**
 * Parse `ps -axo pid=,ppid=,rss=,time=,comm=` stdout into a table keyed by pid.
 *
 * Each line is split into exactly four leading whitespace-delimited fields
 * (pid, ppid, rss, time); the remainder is `comm`, which legitimately contains
 * spaces. Any line that does not yield a valid row is skipped — one weird row
 * must not destroy the table, and this runs at 1 Hz so there is no per-row log.
 */
export function parseProcTable(stdout: string): Map<number, ProcRow> {
  const table = new Map<number, ProcRow>();

  for (const line of stdout.split("\n")) {
    // Four leading whitespace-delimited fields, then the remainder as `comm`.
    // `(.*)` not `(.+)`: a process with an empty name would otherwise be dropped,
    // and losing an intermediate parent orphans its children out of an agent's tree.
    const match = line.trim().match(/^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$/);
    if (!match) continue;

    const [, pidRaw, ppidRaw, rssRaw, timeRaw, comm] = match;

    const pid = parseCount(pidRaw);
    const ppid = parseCount(ppidRaw);
    const rssKib = parseCount(rssRaw);
    const cpuSeconds = parseCpuSeconds(timeRaw);

    if (pid === null || ppid === null || rssKib === null || cpuSeconds === null) {
      continue;
    }

    table.set(pid, {
      pid,
      ppid,
      rssBytes: rssKib * KIB,
      cpuSeconds,
      comm,
    });
  }

  return table;
}

/**
 * Run the single `ps` snapshot and parse it.
 *
 * Owns its own degrade-to-empty guarantee rather than borrowing it from the caller:
 * a rejecting `exec` (spawn fault), a non-zero exit, or empty output all yield an
 * empty table. The collector calls this at 1 Hz forever, so a metrics gap is
 * acceptable and an unhandled rejection that kills the sampler is not.
 */
export async function readProcTable(exec: Exec, timeoutMs?: number): Promise<Map<number, ProcRow>> {
  try {
    const { code, stdout } = await exec("ps", [...PS_ARGS], undefined, timeoutMs);
    return code === 0 ? parseProcTable(stdout) : new Map();
  } catch {
    return new Map();
  }
}
