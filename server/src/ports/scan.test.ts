import assert from "node:assert/strict";
import { test } from "node:test";

import { parseLsofListeners, listListeners, type Exec } from "./scan.js";

// A slice of real `lsof -nP -iTCP -sTCP:LISTEN -FpPnu` output captured on macOS.
// It interleaves the `f` (file-descriptor) and `P` (protocol) records that are
// not requested but always emitted, plus a process (p669) that answers on the
// same port over two file descriptors (IPv4 + IPv6 dual-stack).
const REAL_FIXTURE = [
  "p669",
  "u501",
  "f10",
  "PTCP",
  "n*:61170",
  "f11",
  "PTCP",
  "n*:61170",
  "p769",
  "u501",
  "f9",
  "PTCP",
  "n*:7000",
  "f11",
  "PTCP",
  "n*:5000",
  "p24672",
  "u501",
  "f16",
  "PTCP",
  "n100.119.58.97:7808",
  "f18",
  "PTCP",
  "n127.0.0.1:7808",
].join("\n");

test("parse: process-level state (p/u) persists across the f/P records between names", () => {
  const listeners = parseLsofListeners(REAL_FIXTURE);
  // p769 owns *:7000 and *:5000 even though f/P records sit between the p and the ns.
  const p769 = listeners.filter((l) => l.pid === 769);
  assert.deepEqual(
    p769.map((l) => l.port).sort((a, b) => a - b),
    [5000, 7000],
  );
  assert.ok(p769.every((l) => l.uid === 501));
});

test("parse: one process listening on many ports yields one listener per distinct name", () => {
  const listeners = parseLsofListeners(REAL_FIXTURE);
  const p24672 = listeners.filter((l) => l.pid === 24672);
  assert.deepEqual(
    p24672.map((l) => `${l.address}:${l.port}`).sort(),
    ["100.119.58.97:7808", "127.0.0.1:7808"],
  );
});

test("parse: a wildcard bind reported over two fds collapses to one listener (key dedup)", () => {
  const listeners = parseLsofListeners(REAL_FIXTURE);
  const p669 = listeners.filter((l) => l.pid === 669);
  assert.equal(p669.length, 1, "duplicate pid:address:port from IPv4+IPv6 fds is one row");
  assert.equal(p669[0]!.address, "*");
  assert.equal(p669[0]!.port, 61170);
});

test("parse: `*:5173` yields address '*'", () => {
  const listeners = parseLsofListeners(["p1", "u501", "f3", "PTCP", "n*:5173"].join("\n"));
  assert.deepEqual(listeners, [{ pid: 1, uid: 501, address: "*", port: 5173 }]);
});

test("parse: `[::1]:9787` strips the brackets to '::1'", () => {
  const listeners = parseLsofListeners(["p1", "u501", "f3", "PTCP", "n[::1]:9787"].join("\n"));
  assert.deepEqual(listeners, [{ pid: 1, uid: 501, address: "::1", port: 9787 }]);
});

test("parse: `[::]:5000` strips the brackets to '::'", () => {
  const listeners = parseLsofListeners(["p1", "u501", "f3", "PTCP", "n[::]:5000"].join("\n"));
  assert.deepEqual(listeners, [{ pid: 1, uid: 501, address: "::", port: 5000 }]);
});

test("parse: a name with no colon is skipped, not thrown", () => {
  const listeners = parseLsofListeners(["p1", "u501", "nsomething-weird"].join("\n"));
  assert.deepEqual(listeners, []);
});

test("parse: a non-numeric port is skipped, not thrown", () => {
  const listeners = parseLsofListeners(["p1", "u501", "n127.0.0.1:https"].join("\n"));
  assert.deepEqual(listeners, []);
});

test("parse: a missing uid is tolerated (uid undefined)", () => {
  const listeners = parseLsofListeners(["p1", "n*:8080"].join("\n"));
  assert.equal(listeners.length, 1);
  assert.equal(listeners[0]!.uid, undefined);
});

test("listListeners: a spawn failure → ok:false + a one-line reason, no throw", async () => {
  const exec: Exec = async () => {
    throw new Error("spawn lsof ENOENT");
  };
  const result = await listListeners(exec);
  assert.equal(result.ok, false);
  assert.equal(result.listeners.length, 0);
  assert.match(result.error ?? "", /lsof/);
  assert.ok(!(result.error ?? "").includes("\n"), "reason is one line");
});

test("listListeners: an unavailable command (code 127, empty stdout) → ok:false + reason (missing/timed-out lsof)", async () => {
  // git.run NEVER rejects: a spawn fault or a timeout resolves as
  // {code:127, stdout:"", stderr:msg}. Reported as a real failure, NOT a
  // successful empty scan (which would blank the last good ports).
  const exec: Exec = async () => ({ code: 127, stdout: "", stderr: "lsof: command not found" });
  const result = await listListeners(exec);
  assert.equal(result.ok, false);
  assert.equal(result.listeners.length, 0);
  assert.match(result.error ?? "", /command not found/);
  assert.ok(!(result.error ?? "").includes("\n"), "reason is one line");
});

test("listListeners: a non-zero exit that still parsed listeners returns them (lsof warns routinely)", async () => {
  const exec: Exec = async () => ({ code: 1, stdout: REAL_FIXTURE, stderr: "lsof: WARNING: ..." });
  const result = await listListeners(exec);
  assert.equal(result.ok, true);
  assert.ok(result.listeners.some((l) => l.port === 7808));
});

test("listListeners: passes the -F selector command lsof needs", async () => {
  let seen: { cmd: string; args: string[] } | undefined;
  const exec: Exec = async (cmd, args) => {
    seen = { cmd, args };
    return { code: 0, stdout: "", stderr: "" };
  };
  await listListeners(exec);
  assert.equal(seen?.cmd, "lsof");
  assert.deepEqual(seen?.args, ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpPnu"]);
});
