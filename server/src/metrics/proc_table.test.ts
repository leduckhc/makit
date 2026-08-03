import { test } from "node:test";
import assert from "node:assert/strict";

import { parseProcTable, readProcTable } from "./proc_table.js";
import type { Exec } from "./proc_table.js";

/**
 * Fixtures captured from real `ps -axo pid=,ppid=,rss=,time=,comm=` output.
 * Kept inline (not as files) so the platform-divergent `time=` shapes stay
 * visible next to the assertions that pin them.
 */

// macOS: `time` renders as `mm:ss.cc` for short-lived procs and `hh:mm:ss` for
// long ones; `comm` is the full executable path and may contain spaces.
const MACOS_PS = [
  "    1     0   9600     1:02.34 /sbin/launchd",
  "  842     1  33280     0:03.21 /usr/libexec/Some Daemon.app/Contents/MacOS/Some Daemon",
  " 1337   842 128000    1:02:03 /Applications/Xcode.app/Contents/MacOS/Xcode",
].join("\n");

// Linux: `time` renders as `mm:ss`, `hh:mm:ss`, and `dd-hh:mm:ss` for procs
// running longer than a day. `comm` is the short command name.
const LINUX_PS = [
  "      1       0   12040       01:30 systemd",
  "    440       1    5120    02:03:04 rsyslogd",
  "    991     440   80100 2-03:04:05 postgres",
].join("\n");

test("parses macOS mm:ss.cc time into fractional seconds", () => {
  const table = parseProcTable(MACOS_PS);
  const launchd = table.get(1);
  assert.ok(launchd);
  // 1:02.34 → 62.34s
  assert.equal(launchd.cpuSeconds, 62.34);
});

test("parses macOS hh:mm:ss time", () => {
  const table = parseProcTable(MACOS_PS);
  const xcode = table.get(1337);
  assert.ok(xcode);
  // 1:02:03 → 3723s
  assert.equal(xcode.cpuSeconds, 3723);
});

test("parses Linux mm:ss time", () => {
  const table = parseProcTable(LINUX_PS);
  const systemd = table.get(1);
  assert.ok(systemd);
  // 01:30 → 90s
  assert.equal(systemd.cpuSeconds, 90);
});

test("parses Linux hh:mm:ss time", () => {
  const table = parseProcTable(LINUX_PS);
  const rsyslog = table.get(440);
  assert.ok(rsyslog);
  // 02:03:04 → 7384s
  assert.equal(rsyslog.cpuSeconds, 7384);
});

test("parses Linux dd-hh:mm:ss time", () => {
  const table = parseProcTable(LINUX_PS);
  const pg = table.get(991);
  assert.ok(pg);
  // 2-03:04:05 → 2*86400 + 3*3600 + 4*60 + 5 = 183845s
  assert.equal(pg.cpuSeconds, 183845);
});

test("rss is interpreted as KiB and converted to bytes", () => {
  const table = parseProcTable(LINUX_PS);
  const systemd = table.get(1);
  assert.ok(systemd);
  assert.equal(systemd.rssBytes, 12040 * 1024);
});

test("pid and ppid are captured", () => {
  const table = parseProcTable(LINUX_PS);
  const pg = table.get(991);
  assert.ok(pg);
  assert.equal(pg.pid, 991);
  assert.equal(pg.ppid, 440);
});

test("comm may contain spaces and is taken as the remainder", () => {
  const table = parseProcTable(MACOS_PS);
  const daemon = table.get(842);
  assert.ok(daemon);
  assert.equal(daemon.comm, "/usr/libexec/Some Daemon.app/Contents/MacOS/Some Daemon");
});

test("a garbage row is skipped while its neighbours survive", () => {
  const withGarbage = [
    "      1       0   12040       01:30 systemd",
    "  not-a-real-row-at-all",
    "    440       1    5120    02:03:04 rsyslogd",
  ].join("\n");
  const table = parseProcTable(withGarbage);
  assert.equal(table.size, 2);
  assert.ok(table.get(1));
  assert.ok(table.get(440));
});

test("a row with an unparseable time is skipped, not fatal", () => {
  const withBadTime = [
    "      1       0   12040       01:30 systemd",
    "    440       1    5120    99:aa:bb rsyslogd",
    "    991     440   80100 2-03:04:05 postgres",
  ].join("\n");
  const table = parseProcTable(withBadTime);
  assert.equal(table.size, 2);
  assert.equal(table.has(440), false);
  assert.ok(table.get(991));
});

test("empty stdout yields an empty map", () => {
  assert.equal(parseProcTable("").size, 0);
});

test("whitespace-only stdout yields an empty map", () => {
  assert.equal(parseProcTable("   \n  \n\t\n").size, 0);
});

test("readProcTable invokes exec with the exact ps argv", async () => {
  const calls: Array<{ cmd: string; args: string[] }> = [];
  const exec: Exec = async (cmd, args) => {
    calls.push({ cmd, args });
    return { code: 0, stdout: LINUX_PS, stderr: "" };
  };
  const table = await readProcTable(exec);

  assert.equal(calls.length, 1);
  assert.equal(calls[0].cmd, "ps");
  assert.deepEqual(calls[0].args, ["-axo", "pid=,ppid=,rss=,time=,comm="]);
  assert.equal(table.size, 3);
});

test("readProcTable returns an empty map when exec fails, never throws", async () => {
  const exec: Exec = async () => ({ code: 1, stdout: "", stderr: "ps: not found" });
  const table = await readProcTable(exec);
  assert.equal(table.size, 0);
});
