/**
 * watch_store — pure persistence for watched ports (SPEC-44 D7).
 *
 * `$MAKIT_HOME/watched-ports.json` (override `MAKIT_WATCHED_PORTS_FILE`), shaped
 * as a flat array of `{worktreePath, port}`. Mirrors `history_store.ts` /
 * `project-store.ts` one-for-one: load and save **never throw**, a corrupt or
 * missing file degrades to an empty list so the server always starts, and a
 * write failure is logged and swallowed.
 *
 * The identity is `(worktreePath, port)` and deliberately NOT the snapshot `key`:
 * SPEC-41 D6 forbids persisting `<pid>:<address>:<port>` because pids are reused
 * and a restart changes the pid for the same endpoint — and surviving a
 * dev-server restart is the entire point of watching one.
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { makitHome } from "../daemon/paths.js";
import { log } from "../log.js";

/** One watched endpoint. */
export interface WatchedPort {
  worktreePath: string;
  port: number;
}

/** Absolute path of the watched-ports file. */
export function watchedPortsFile(): string {
  return process.env.MAKIT_WATCHED_PORTS_FILE ?? join(makitHome(), "watched-ports.json");
}

function isWatchedPort(value: unknown): value is WatchedPort {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.worktreePath === "string" &&
    v.worktreePath.length > 0 &&
    typeof v.port === "number" &&
    Number.isInteger(v.port)
  );
}

/**
 * Read the watch list. Anything unreadable is an empty list; inside a valid
 * array, individual junk entries are skipped and the good ones kept.
 */
export function loadWatchedPorts(file: string = watchedPortsFile()): WatchedPort[] {
  try {
    if (!existsSync(file)) return [];
    const parsed: unknown = JSON.parse(readFileSync(file, "utf8"));
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isWatchedPort).map((w) => ({ worktreePath: w.worktreePath, port: w.port }));
  } catch (err) {
    log.warn(`[ports] watched-ports unreadable, ignoring: ${(err as Error).message}`);
    return [];
  }
}

/**
 * Persist the watch list. A failure is logged and swallowed.
 *
 * Written to a sibling temp file and renamed, because `writeFileSync` truncates
 * first: a process that stops mid-write would leave a partial file, which
 * {@link loadWatchedPorts} then degrades to an empty list — silently losing every
 * watch the user had set. `rename` within a directory is atomic, so a reader sees
 * either the old file or the new one.
 */
export function saveWatchedPorts(file: string, watched: WatchedPort[]): void {
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(tmp, `${JSON.stringify(watched, null, 2)}\n`);
    renameSync(tmp, file);
  } catch (err) {
    log.warn(`[ports] could not save watched-ports: ${(err as Error).message}`);
    try {
      if (existsSync(tmp)) rmSync(tmp, { force: true });
    } catch {
      /* best-effort: a stray temp file must not escalate */
    }
  }
}

/** Add or remove one watch. Pure: returns a new list. */
export function setWatchedPort(
  watched: WatchedPort[],
  target: WatchedPort,
  on: boolean,
): WatchedPort[] {
  const without = watched.filter(
    (w) => !(w.worktreePath === target.worktreePath && w.port === target.port),
  );
  return on ? [...without, { worktreePath: target.worktreePath, port: target.port }] : without;
}

/**
 * Whether this endpoint is watched. Both fields must match: two worktrees can
 * each run a dev server on 5173, and watching one is not watching the other.
 */
export function isWatched(
  watched: WatchedPort[],
  worktreePath: string | undefined,
  port: number,
): boolean {
  if (worktreePath === undefined) return false;
  return watched.some((w) => w.worktreePath === worktreePath && w.port === port);
}
