/**
 * `makit compact` — the two promises the command makes on the command line.
 *
 * 1. `--force` means "the daemon is running, compact anyway". It must not also
 *    change WHAT is compacted: an unfinished turn is only spared because a live
 *    digest still owns it, so with no daemon there is nothing to spare.
 * 2. `--dry-run` reports and changes nothing. Opening the store read-write would
 *    run `migrate()` and set persistent pragmas, so a report would silently
 *    upgrade the very database it was only asked to describe.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

import { runCompact } from "./compact.js";
import { SqliteEventStore } from "../storage/sqlite_event_store.js";

/** Capture stdout, so the assertions read the report the user would see. */
async function captureOut(fn: () => Promise<void>): Promise<string> {
  const original = console.log;
  let out = "";
  console.log = (...args: unknown[]) => {
    out += `${args.join(" ")}\n`;
  };
  try {
    await fn();
  } finally {
    console.log = original;
  }
  return out;
}

/** A log holding one session whose last turn never finished. */
function dbWithOpenTurn(dir: string): string {
  const path = join(dir, "makit.db");
  const store = new SqliteEventStore(path);
  store.saveSession({
    id: "s1",
    projectId: "p",
    agent: "pi",
    title: "t",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 1,
    lastPreview: "",
  });
  store.append("s1", { ts: 1, kind: "session.status", payload: { status: "running" } });
  for (const chunk of ["never ", "finished ", "turn"]) {
    store.append("s1", { ts: 2, kind: "agent.message.delta", payload: { msgId: "m1", chunk } });
  }
  store.close();
  return path;
}

test("--force does not spare an open turn when no daemon is running", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-compact-"));
  try {
    const path = dbWithOpenTurn(dir);
    // No daemon holds this db (`--db` points outside the home), so --force only
    // means "do not refuse"; the stalled turn must still be aggregated.
    const out = await captureOut(() => runCompact(["--db", path, "--force"]));

    const store = new SqliteEventStore(path);
    const kinds = store.read("s1", 0).map((e) => e.kind);
    store.close();
    assert.deepEqual(kinds, ["session.status", "agent.message"], out);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("--dry-run reports the rows without migrating the schema it opened", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-compact-"));
  try {
    // A log written by an OLDER makit: `sessions` has none of the columns that
    // `migrate()` adds, and the journal is not WAL. Both are visible evidence of
    // a write, so a dry run must leave them exactly as they are.
    const path = join(dir, "old.db");
    const raw = new DatabaseSync(path);
    raw.exec("PRAGMA journal_mode = DELETE;");
    raw.exec(`
      CREATE TABLE sessions (id TEXT PRIMARY KEY, project_id TEXT NOT NULL);
      CREATE TABLE events (
        session_id TEXT NOT NULL, seq INTEGER NOT NULL, ts INTEGER NOT NULL,
        kind TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (session_id, seq)
      );
      INSERT INTO sessions VALUES ('s1', 'p');
      INSERT INTO events VALUES ('s1', 1, 1, 'agent.message.delta', '{"chunk":"a"}');
      INSERT INTO events VALUES ('s1', 2, 2, 'agent.message.delta', '{"chunk":"b"}');
      INSERT INTO events VALUES ('s1', 3, 3, 'agent.message', '{"text":"ab"}');
    `);
    raw.close();

    const out = await captureOut(() => runCompact(["--db", path, "--dry-run"]));
    assert.match(out, /2 delta rows in 1 sessions/, out);

    const after = new DatabaseSync(path);
    const columns = (after.prepare("PRAGMA table_info(sessions)").all() as Array<{ name: string }>)
      .map((c) => c.name);
    const journal = (after.prepare("PRAGMA journal_mode").get() as { journal_mode: string })
      .journal_mode;
    after.close();

    assert.deepEqual(columns, ["id", "project_id"], "a dry run must not add columns");
    assert.equal(journal, "delete", "a dry run must not switch the journal to WAL");
    assert.equal(existsSync(`${path}-wal`), false, "and must leave no WAL sidecar behind");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("--dry-run counts the deltas of every session, and removes nothing", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-compact-"));
  try {
    const path = dbWithOpenTurn(dir);
    const out = await captureOut(() => runCompact(["--db", path, "--dry-run"]));
    assert.match(out, /3 delta rows in 1 sessions/, out);

    const store = new SqliteEventStore(path);
    assert.equal(store.read("s1", 0).length, 4, "the log is untouched");
    store.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
