/**
 * `makit compact` — shrink the event log by removing streamed deltas.
 *
 * The log used to keep one row per streamed token. One profile database held
 * 1,795,475 rows in 730 MB, 93% of them deltas that a final already superseded.
 * `stream_digest.ts` stopped writing them; this removes the ones already there
 * and reclaims the disk.
 *
 * Read-only by default (`--dry-run` reports and changes nothing, on a read-only
 * connection), and it refuses to touch a database a running daemon holds unless
 * the caller insists.
 */

import { existsSync, statSync } from "node:fs";
import { resolve as resolvePath } from "node:path";
import { DatabaseSync } from "node:sqlite";

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

/**
 * Count the delta rows a real run would remove, WITHOUT writing.
 *
 * Deliberately not `SqliteEventStore`: its constructor runs `migrate()` and sets
 * `journal_mode = WAL`, both of which persist in the file. A dry run that
 * upgraded the schema of the database it was only asked to describe would break
 * its own promise, so this opens a read-only connection and asks SQL to count.
 */
function dryRunCounts(dbPath: string): { rows: number; sessions: number } {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const row = db
      .prepare(
        "SELECT COUNT(*) AS rows, COUNT(DISTINCT session_id) AS sessions " +
          "FROM events WHERE kind LIKE '%.delta'",
      )
      .get() as { rows: number; sessions: number };
    return { rows: row.rows, sessions: row.sessions };
  } finally {
    db.close();
  }
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

  if (dryRun) {
    // Report what a real run would remove, and change nothing at all.
    const { rows, sessions } = dryRunCounts(dbPath);
    console.log(`[makit] dry run: ${rows} delta rows in ${sessions} sessions would go`);
    return;
  }

  const store = new SqliteEventStore(dbPath);
  try {
    // An open turn is spared only because a LIVE digest still owns its text and
    // will write the aggregate at the close. `--force` says "the daemon is
    // running, compact anyway"; it must not also spare a turn on a stopped
    // daemon, which would leave those rows for nothing to ever collapse.
    const keepOpenTurn = pid !== undefined;
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
