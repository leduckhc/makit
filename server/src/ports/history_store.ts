/**
 * history_store — pure persistence for the port-history feature (SPEC-ports-global-view D11).
 *
 * A single small JSON file (`$MAKIT_HOME/port-history.json` by default,
 * overridable via MAKIT_PORT_HISTORY_FILE) shaped `{ "entries": […] }`, mirroring
 * `project-store.ts` one-for-one: load/save never throw on bad input — a corrupt
 * or missing file degrades to an empty history so the server always starts, and a
 * write failure is logged and swallowed.
 *
 * It records, per worktree, the branch that owned it and the ports it has been
 * seen binding. This is a BOUNDED map, not an append-only log: entries older than
 * {@link HISTORY_TTL_MS} are dropped on save and each entry's port list is capped
 * at {@link MAX_PORTS_PER_ENTRY} — so it stays tiny and needs no sqlite (D11).
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { makitHome } from "../daemon/paths.js";
import { log } from "../log.js";

/** One remembered worktree: the branch that owned it and the ports it has bound. */
export interface PortHistoryEntry {
  /** Absolute worktree path — the map key. */
  worktreePath: string;
  /** Branch label at last sighting; absent when history never recorded one. */
  branch?: string;
  /** Distinct port numbers this worktree has been seen listening on (bounded). */
  ports: number[];
  /** Epoch ms first recorded. */
  firstSeen: number;
  /** Epoch ms last seen ACTIVE + owning ≥1 listener — drives "removed Nd ago". */
  lastSeen: number;
}

export interface PortHistory {
  entries: PortHistoryEntry[];
}

/**
 * Entries whose `lastSeen` is older than this are dropped on save. 14 days: long
 * enough to still explain a port a developer forgot about last week, short enough
 * that a machine reimaged a fortnight ago does not carry ghosts forever.
 */
export const HISTORY_TTL_MS = 14 * 24 * 60 * 60 * 1000;

/**
 * Per-entry port cap. A single worktree cycling through many dev-server ports
 * (each `pnpm dev` picking the next free one) must not grow an entry without
 * bound. 32 comfortably covers a busy worktree while capping the outlier; the
 * OLDEST ports are evicted first so the most recent bindings survive.
 */
export const MAX_PORTS_PER_ENTRY = 32;

/** Absolute path of the port-history persistence file. */
export function historyFile(): string {
  return process.env.MAKIT_PORT_HISTORY_FILE ?? join(makitHome(), "port-history.json");
}

function isEntry(value: unknown): value is PortHistoryEntry {
  if (typeof value !== "object" || value === null) return false;
  const e = value as Record<string, unknown>;
  return (
    typeof e.worktreePath === "string" &&
    Array.isArray(e.ports) &&
    e.ports.every((p) => typeof p === "number") &&
    typeof e.firstSeen === "number" &&
    typeof e.lastSeen === "number" &&
    (e.branch === undefined || typeof e.branch === "string")
  );
}

/**
 * Read the port history. A missing or malformed file yields `{entries:[]}` —
 * this must never throw so startup is robust against a corrupt store (mirrors
 * `loadProjects`). Each entry is validated in isolation; a malformed row is
 * skipped rather than aborting the whole load.
 */
export function loadHistory(file: string): PortHistory {
  try {
    if (!existsSync(file)) return { entries: [] };
    const parsed = JSON.parse(readFileSync(file, "utf8")) as unknown;
    if (typeof parsed !== "object" || parsed === null) return { entries: [] };
    const raw = (parsed as { entries?: unknown }).entries;
    if (!Array.isArray(raw)) return { entries: [] };
    const entries: PortHistoryEntry[] = [];
    for (const row of raw) {
      if (!isEntry(row)) continue;
      const entry: PortHistoryEntry = {
        worktreePath: row.worktreePath,
        ports: [...row.ports],
        firstSeen: row.firstSeen,
        lastSeen: row.lastSeen,
      };
      if (row.branch !== undefined) entry.branch = row.branch;
      entries.push(entry);
    }
    return { entries };
  } catch (e) {
    log.warn(`[makit] failed to read port history file ${file}: ${(e as Error).message}`);
    return { entries: [] };
  }
}

/**
 * Persist the history as pretty JSON, creating the parent dir if needed. Entries
 * older than {@link HISTORY_TTL_MS} (by `lastSeen` relative to `now`) are dropped.
 * Never throws — a write failure is logged and swallowed (mirrors `saveProjects`).
 */
export function saveHistory(file: string, history: PortHistory, now: number): void {
  try {
    const cutoff = now - HISTORY_TTL_MS;
    const entries = history.entries.filter((e) => e.lastSeen >= cutoff);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, JSON.stringify({ entries }, null, 2) + "\n");
  } catch (e) {
    log.warn(`[makit] failed to write port history file ${file}: ${(e as Error).message}`);
  }
}

/** The fields naming a single sighting of a worktree binding a port. */
export interface UpsertInput {
  worktreePath: string;
  branch?: string;
  port: number;
  now: number;
}

/**
 * Record one (worktree, port) sighting, returning a NEW history — pure, the input
 * is never mutated. A new worktree stamps `firstSeen`/`lastSeen`; an existing one
 * keeps `firstSeen`, refreshes `branch`, adds the port (deduped, oldest evicted
 * past {@link MAX_PORTS_PER_ENTRY}) and bumps `lastSeen`.
 */
export function upsertEntry(history: PortHistory, input: UpsertInput): PortHistory {
  const { worktreePath, branch, port, now } = input;
  let found = false;
  const entries = history.entries.map((e): PortHistoryEntry => {
    if (e.worktreePath !== worktreePath) return e;
    found = true;
    const ports = e.ports.includes(port) ? [...e.ports] : [...e.ports, port];
    const capped = ports.length > MAX_PORTS_PER_ENTRY ? ports.slice(ports.length - MAX_PORTS_PER_ENTRY) : ports;
    const next: PortHistoryEntry = {
      worktreePath,
      ports: capped,
      firstSeen: e.firstSeen,
      lastSeen: now,
    };
    if (branch !== undefined) next.branch = branch;
    else if (e.branch !== undefined) next.branch = e.branch;
    return next;
  });
  if (!found) {
    const entry: PortHistoryEntry = { worktreePath, ports: [port], firstSeen: now, lastSeen: now };
    if (branch !== undefined) entry.branch = branch;
    entries.push(entry);
  }
  return { entries };
}
