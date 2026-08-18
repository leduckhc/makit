/**
 * `makit compact` — shrink the event log by removing streamed deltas.
 *
 * The log used to keep one row per streamed token. One profile database held
 * 1,795,475 rows in 730 MB, 93% of them deltas that a final already superseded.
 * `stream_digest.ts` stopped writing them; this removes the ones already there
 * and reclaims the disk.
 *
 * Read-only by default (`--dry-run` reports and changes nothing), and it refuses
 * to touch a database a running daemon holds unless the caller insists.
 */

import { existsSync, statSync } from "node:fs";
import { resolve as resolvePath } from "node:path";

import { SqliteEventStore } from "../storage/sqlite_event_store.js";
import { compactAll, compactSessionLog } from "../storage/compact.js";
import { makitHome, pidFilePath } from "../daemon/paths.js";
import { readFileSync } from "node:fs";

/** Human-readable size, so a 730 MB before/after is legible at a glance. */
function mb(bytes: number): string {
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/** The pid of a running daemon, or undefined when none holds this home. */
function runningDaemonPid(): number | undefined {
  try {
    const pid = Number(readFileSync(pidFilePath(), "utf8").trim());
    if (!Number.isInteger(pid) || pid <= 0) return undefined;
    process.kill(pid, 0);
    return pid;
  } catch {
    return undefined;
  }
}

/**
 * True when [dbPath] is the database this home's daemon would open. A `--db`
 * pointing anywhere else (another profile, a copy) is unrelated to the pid file,
 * so the running-daemon guard must not fire on it.
 */
function sameHomeAsDaemon(dbPath: string): boolean {
  const home = resolvePath(process.env.MAKIT_DB_FILE ?? `${makitHome()}/makit.db`);
  return dbPath === home;
}

export async function runCompact(argv: string[]): Promise<void> {
  const dryRun = argv.includes("--dry-run");
  const force = argv.includes("--force");
  const dbFlag = argv.indexOf("--db");
  const dbPath = resolvePath(
    dbFlag >= 0 && argv[dbFlag + 1] !== undefined
      ? argv[dbFlag + 1]
      : (process.env.MAKIT_DB_FILE ?? `${makitHome()}/makit.db`),
  );

  if (!existsSync(dbPath)) {
    console.error(`[makit] no event log at ${dbPath}`);
    process.exit(1);
  }

  const pid = sameHomeAsDaemon(dbPath) ? runningDaemonPid() : undefined;
  if (pid !== undefined && !force && !dryRun) {
    console.error(
      `[makit] the daemon is running (pid ${pid}). Stop it with \`makit stop\`, ` +
        `or pass --force to compact anyway.`,
    );
    process.exit(2);
  }

  const before = statSync(dbPath).size;
  console.log(`[makit] event log: ${dbPath} (${mb(before)})`);

  const store = new SqliteEventStore(dbPath);
  try {
    if (dryRun) {
      // Count against a copy of the rules without writing: read each session,
      // and report what a real run would remove.
      let rows = 0;
      let sessions = 0;
      for (const id of store.eventSessionIds()) {
        sessions++;
        rows += store
          .read(id, 0)
          .filter((e) => e.kind.endsWith(".delta")).length;
      }
      console.log(`[makit] dry run: ${rows} delta rows in ${sessions} sessions would go`);
      return;
    }

    // A live daemon may be streaming the last turn, so leave it alone (--force).
    const keepOpenTurn = pid !== undefined || force;
    const totals = compactAll(store, {
      keepOpenTurn,
      onSession: (id, r) => {
        if (r.removed > 0) {
          console.log(
            `[makit]   ${id.slice(0, 8)}: −${r.removed} rows, ` +
              `+${r.aggregated} aggregated, ${r.rewritten} rewritten`,
          );
        }
      },
    });
    const after = statSync(dbPath).size;
    console.log(
      `[makit] compacted ${totals.sessions} sessions: −${totals.removed} rows, ` +
        `+${totals.aggregated} aggregated. ${mb(before)} → ${mb(after)}`,
    );
  } finally {
    store.close();
  }
}

/** Exported for the test: one session, by id. */
export { compactSessionLog };
