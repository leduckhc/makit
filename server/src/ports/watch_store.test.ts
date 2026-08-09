import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  loadWatchedPorts,
  saveWatchedPorts,
  setWatchedPort,
  isWatched,
  watchedPortsFile,
  type WatchedPort,
} from "./watch_store.js";

const A: WatchedPort = { worktreePath: "/repo/wt-a", port: 5173 };
const B: WatchedPort = { worktreePath: "/repo/wt-b", port: 5174 };

function tmp(): string {
  return mkdtempSync(join(tmpdir(), "makit-watched-"));
}

test("a missing file loads as an empty list (never throws)", () => {
  const dir = tmp();
  try {
    assert.deepEqual(loadWatchedPorts(join(dir, "nope.json")), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("corrupt JSON, a non-array, and garbled entries all degrade — never throw", () => {
  const dir = tmp();
  try {
    const file = join(dir, "bad.json");
    writeFileSync(file, "{ not json ");
    assert.deepEqual(loadWatchedPorts(file), []);
    writeFileSync(file, JSON.stringify({ nope: true }));
    assert.deepEqual(loadWatchedPorts(file), []);
    // One good entry survives a list full of junk: a watch list that cannot be
    // read must not break startup, and one bad row must not drop the rest.
    writeFileSync(
      file,
      JSON.stringify([null, 7, { port: 5173 }, { worktreePath: "/x" }, A, { worktreePath: "/y", port: "80" }]),
    );
    assert.deepEqual(loadWatchedPorts(file), [A]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("save → load round-trips, creating parent directories", () => {
  const dir = tmp();
  try {
    const file = join(dir, "nested", "watched-ports.json");
    saveWatchedPorts(file, [A, B]);
    assert.deepEqual(loadWatchedPorts(file), [A, B]);
    // Readable JSON on disk, so a user can inspect (and delete) it by hand.
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), [A, B]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a write failure is swallowed, not thrown", () => {
  const dir = tmp();
  try {
    chmodSync(dir, 0o500); // read+execute only → no writes
    assert.doesNotThrow(() => saveWatchedPorts(join(dir, "watched.json"), [A]));
  } finally {
    chmodSync(dir, 0o700);
    rmSync(dir, { recursive: true, force: true });
  }
});

test("setWatchedPort adds, is idempotent, and removes", () => {
  // Identity is `(worktreePath, port)` (D7): a pid would be worthless here,
  // because surviving a dev-server restart is the entire point of watching.
  let list = setWatchedPort([], A, true);
  assert.deepEqual(list, [A]);
  list = setWatchedPort(list, A, true);
  assert.deepEqual(list, [A], "watching twice is not two watches");
  list = setWatchedPort(list, B, true);
  assert.deepEqual(list, [A, B]);
  list = setWatchedPort(list, A, false);
  assert.deepEqual(list, [B]);
  list = setWatchedPort(list, A, false);
  assert.deepEqual(list, [B], "un-watching what is not watched is a no-op");
});

test("isWatched matches on both fields, never on the port alone", () => {
  const list = [A];
  assert.equal(isWatched(list, "/repo/wt-a", 5173), true);
  assert.equal(isWatched(list, "/repo/wt-a", 5174), false);
  assert.equal(
    isWatched(list, "/repo/wt-b", 5173),
    false,
    "two worktrees may both use 5173 — watching one is not watching the other",
  );
  assert.equal(isWatched(list, undefined, 5173), false);
});

test("the file path honours MAKIT_WATCHED_PORTS_FILE", () => {
  const prev = process.env.MAKIT_WATCHED_PORTS_FILE;
  try {
    process.env.MAKIT_WATCHED_PORTS_FILE = "/tmp/custom-watched.json";
    assert.equal(watchedPortsFile(), "/tmp/custom-watched.json");
    delete process.env.MAKIT_WATCHED_PORTS_FILE;
    assert.match(watchedPortsFile(), /watched-ports\.json$/);
  } finally {
    if (prev === undefined) delete process.env.MAKIT_WATCHED_PORTS_FILE;
    else process.env.MAKIT_WATCHED_PORTS_FILE = prev;
  }
});
