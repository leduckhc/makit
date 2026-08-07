import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  loadHistory,
  saveHistory,
  historyFile,
  upsertEntry,
  HISTORY_TTL_MS,
  MAX_PORTS_PER_ENTRY,
  type PortHistory,
} from "./history_store.js";

test("loadHistory returns {entries:[]} for a missing file", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-porthist-"));
  try {
    assert.deepEqual(loadHistory(join(dir, "nope.json")), { entries: [] });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("loadHistory returns {entries:[]} for corrupt JSON (never throws)", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-porthist-"));
  try {
    const file = join(dir, "bad.json");
    writeFileSync(file, "{ not valid json ");
    assert.deepEqual(loadHistory(file), { entries: [] });
    writeFileSync(file, JSON.stringify({ entries: "not-an-array" }));
    assert.deepEqual(loadHistory(file), { entries: [] });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("saveHistory / loadHistory round-trips entries", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-porthist-"));
  try {
    const file = join(dir, "nested", "port-history.json");
    const now = 1_700_000_000_000;
    const history: PortHistory = {
      entries: [
        { worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: now, lastSeen: now },
      ],
    };
    saveHistory(file, history, now);
    assert.deepEqual(loadHistory(file), history);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("historyFile honours the MAKIT_PORT_HISTORY_FILE override", () => {
  const prev = process.env.MAKIT_PORT_HISTORY_FILE;
  try {
    process.env.MAKIT_PORT_HISTORY_FILE = "/tmp/custom-port-history.json";
    assert.equal(historyFile(), "/tmp/custom-port-history.json");
  } finally {
    if (prev === undefined) delete process.env.MAKIT_PORT_HISTORY_FILE;
    else process.env.MAKIT_PORT_HISTORY_FILE = prev;
  }
});

test("upsertEntry adds a new worktree with the port and stamps first/last seen", () => {
  const now = 1_700_000_000_000;
  const next = upsertEntry(
    { entries: [] },
    { worktreePath: "/repo/wt-a", branch: "feat/a", port: 5173, now },
  );
  assert.deepEqual(next.entries, [
    { worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: now, lastSeen: now },
  ]);
});

test("upsertEntry adds a port + bumps lastSeen, preserving firstSeen (pure — no input mutation)", () => {
  const start = 1_700_000_000_000;
  const input: PortHistory = {
    entries: [
      { worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: start, lastSeen: start },
    ],
  };
  const later = start + 60_000;
  const next = upsertEntry(input, { worktreePath: "/repo/wt-a", branch: "feat/a", port: 5174, now: later });
  // Input is untouched.
  assert.deepEqual(input.entries[0]!.ports, [5173]);
  assert.equal(input.entries[0]!.lastSeen, start);
  // Output has the new port and bumped lastSeen, firstSeen preserved.
  assert.deepEqual(next.entries[0]!.ports, [5173, 5174]);
  assert.equal(next.entries[0]!.firstSeen, start);
  assert.equal(next.entries[0]!.lastSeen, later);
});

test("upsertEntry does not duplicate an already-recorded port", () => {
  const now = 1_700_000_000_000;
  const next = upsertEntry(
    { entries: [{ worktreePath: "/repo/wt-a", branch: "feat/a", ports: [5173], firstSeen: now, lastSeen: now }] },
    { worktreePath: "/repo/wt-a", branch: "feat/a", port: 5173, now: now + 1000 },
  );
  assert.deepEqual(next.entries[0]!.ports, [5173]);
});

test("upsertEntry caps ports per entry at MAX_PORTS_PER_ENTRY, keeping the most recent", () => {
  const now = 1_700_000_000_000;
  let history: PortHistory = { entries: [] };
  for (let i = 0; i <= MAX_PORTS_PER_ENTRY; i++) {
    history = upsertEntry(history, { worktreePath: "/repo/wt-a", branch: "feat/a", port: 3000 + i, now: now + i });
  }
  const ports = history.entries[0]!.ports;
  assert.equal(ports.length, MAX_PORTS_PER_ENTRY);
  // The oldest (3000) was evicted; the newest is kept.
  assert.ok(!ports.includes(3000));
  assert.ok(ports.includes(3000 + MAX_PORTS_PER_ENTRY));
});

test("saveHistory drops entries older than HISTORY_TTL_MS", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-porthist-"));
  try {
    const file = join(dir, "port-history.json");
    const now = 1_700_000_000_000;
    const history: PortHistory = {
      entries: [
        { worktreePath: "/fresh", branch: "a", ports: [1], firstSeen: now, lastSeen: now },
        { worktreePath: "/stale", branch: "b", ports: [2], firstSeen: 0, lastSeen: now - HISTORY_TTL_MS - 1 },
      ],
    };
    saveHistory(file, history, now);
    const reloaded = loadHistory(file);
    assert.deepEqual(reloaded.entries.map((e) => e.worktreePath), ["/fresh"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("saveHistory swallows a write failure (never throws)", () => {
  // A path whose parent cannot be created (a file segment used as a directory)
  // makes mkdirSync throw ENOTDIR; the store must log-and-swallow, not crash.
  const dir = mkdtempSync(join(tmpdir(), "makit-porthist-"));
  try {
    const notADir = join(dir, "afile");
    writeFileSync(notADir, "x");
    const file = join(notADir, "cannot", "port-history.json");
    assert.doesNotThrow(() => saveHistory(file, { entries: [] }, 0));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("saveHistory writes pretty JSON", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-porthist-"));
  try {
    const file = join(dir, "port-history.json");
    saveHistory(file, { entries: [] }, 0);
    const text = readFileSync(file, "utf8");
    assert.match(text, /\n/, "pretty-printed with newlines");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
