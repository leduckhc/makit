import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  parseProcs,
  readProcs,
  readCwds,
  parseLsofCwds,
  createRealpathResolver,
  type Exec,
} from "./proc.js";

const NOW = 1_700_000_000_000;

test("parse: argv containing spaces survives whole (rest-of-line, not split)", () => {
  const procs = parseProcs("  742   700    01:02:03 node /path/to/vite --host 0.0.0.0 --port 5173\n", NOW);
  const p = procs.get(742);
  assert.equal(p?.command, "node /path/to/vite --host 0.0.0.0 --port 5173");
  assert.equal(p?.ppid, 700);
});

test("parse: etime mm:ss → startedAt (now minus elapsed)", () => {
  const procs = parseProcs("1 0 05:23 launchd", NOW);
  assert.equal(procs.get(1)?.startedAt, NOW - (5 * 60 + 23) * 1000);
});

test("parse: etime hh:mm:ss → startedAt", () => {
  const procs = parseProcs("1 0 01:55:53 node", NOW);
  assert.equal(procs.get(1)?.startedAt, NOW - (1 * 3600 + 55 * 60 + 53) * 1000);
});

test("parse: etime dd-hh:mm:ss → startedAt", () => {
  const procs = parseProcs("1 0 13-04:22:59 launchd", NOW);
  const elapsed = 13 * 86400 + 4 * 3600 + 22 * 60 + 59;
  assert.equal(procs.get(1)?.startedAt, NOW - elapsed * 1000);
});

test("parse: an unparsable etime OMITS startedAt (never epoch 0 → 'up 56y')", () => {
  const procs = parseProcs("1 0 ?? launchd", NOW);
  const p = procs.get(1);
  assert.ok(p, "the row is still kept");
  assert.equal(p?.startedAt, undefined);
});

test("parse: a malformed line is skipped, the rest kept", () => {
  const procs = parseProcs(["garbage-with-no-fields", "742 700 01:02:03 node server.js"].join("\n"), NOW);
  assert.equal(procs.size, 1);
  assert.equal(procs.get(742)?.command, "node server.js");
});

test("readCwds([]) issues NO command (an empty -p would make lsof dump the machine)", async () => {
  let called = false;
  const exec: Exec = async () => {
    called = true;
    return { code: 0, stdout: "", stderr: "" };
  };
  const result = await readCwds(exec, []);
  assert.equal(called, false);
  assert.equal(result.ok, true);
  assert.equal(result.cwds.size, 0);
});

test("readCwds: builds one comma-separated -p and parses fcwd/n records", async () => {
  let seen: string[] | undefined;
  const exec: Exec = async (_cmd, args) => {
    seen = args;
    return {
      code: 0,
      stdout: ["p742", "fcwd", "n/Users/le/work/repo/wt-a", "p900", "fcwd", "n/Users/le/other"].join("\n"),
      stderr: "",
    };
  };
  const result = await readCwds(exec, [742, 900]);
  assert.deepEqual(seen, ["-a", "-d", "cwd", "-Fpn", "-p", "742,900"]);
  assert.equal(result.ok, true);
  assert.equal(result.cwds.get(742), "/Users/le/work/repo/wt-a");
  assert.equal(result.cwds.get(900), "/Users/le/other");
});

test("readCwds: an UNAVAILABLE command (code 127, empty stdout) → ok:false + reason", async () => {
  const exec: Exec = async () => ({ code: 127, stdout: "", stderr: "lsof: command not found" });
  const result = await readCwds(exec, [742]);
  assert.equal(result.ok, false);
  assert.equal(result.cwds.size, 0);
  assert.match(result.error ?? "", /command not found/);
});

test("readCwds: a non-zero exit that STILL printed cwds is ok (lsof warns routinely)", async () => {
  const exec: Exec = async () => ({
    code: 1,
    stdout: ["p742", "fcwd", "n/repo/wt-a"].join("\n"),
    stderr: "lsof: WARNING: ...",
  });
  const result = await readCwds(exec, [742]);
  assert.equal(result.ok, true);
  assert.equal(result.cwds.get(742), "/repo/wt-a");
});

test("readProcs: a non-zero exit → ok:false + reason (ps does not warn like lsof)", async () => {
  const exec: Exec = async () => ({ code: 1, stdout: "", stderr: "ps: illegal option" });
  const result = await readProcs(exec, NOW);
  assert.equal(result.ok, false);
  assert.equal(result.procs.size, 0);
  assert.match(result.error ?? "", /ps failed/);
});

test("readProcs: a clean exit → ok:true with the parsed table", async () => {
  const exec: Exec = async () => ({ code: 0, stdout: "742 700 01:02:03 node server.js", stderr: "" });
  const result = await readProcs(exec, NOW);
  assert.equal(result.ok, true);
  assert.equal(result.procs.get(742)?.command, "node server.js");
});

test("parseLsofCwds: a spawn/parse hiccup never throws, just yields what parsed", () => {
  const cwds = parseLsofCwds(["p1", "fcwd", "n/a", "garbage"].join("\n"));
  assert.equal(cwds.get(1), "/a");
});

test("parseLsofCwds: an annotation `n` line without a preceding `fcwd` is NOT stored as a cwd", () => {
  // Some lsof versions emit `n(readlink: Permission denied)` alongside the real
  // cwd record; storing it would mis-attribute the process to a bogus path.
  const cwds = parseLsofCwds(
    ["p1", "fcwd", "n/repo/wt-a", "n(readlink: Permission denied)"].join("\n"),
  );
  assert.equal(cwds.get(1), "/repo/wt-a");
});

test("parseLsofCwds: an `n` before any `fcwd` for a pid is ignored", () => {
  const cwds = parseLsofCwds(["p1", "n(something)", "fcwd", "n/repo/wt-a"].join("\n"));
  assert.equal(cwds.get(1), "/repo/wt-a");
});

test("realpath resolver: /tmp and /private/tmp resolve equal on macOS, and it memoises", () => {
  let calls = 0;
  const resolve = createRealpathResolver((p) => {
    calls++;
    // Emulate macOS's /tmp → /private/tmp symlink without touching the disk.
    return p.startsWith("/private/") ? p : `/private${p}`;
  });
  assert.equal(resolve("/tmp/x"), "/private/tmp/x");
  assert.equal(resolve("/private/tmp/x"), "/private/tmp/x");
  // A repeat of the same input hits the cache.
  assert.equal(resolve("/tmp/x"), "/private/tmp/x");
  assert.equal(calls, 2, "one call per distinct input path");
});

test("realpath resolver: an unresolvable path falls back to the input (no throw)", () => {
  const missing = join(mkdtempSync(join(tmpdir(), "ports-")), "does-not-exist");
  const resolve = createRealpathResolver();
  assert.equal(resolve(missing), missing);
});
