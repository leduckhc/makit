/**
 * launchd LaunchAgent plist tests (SPEC-01, phase 5).
 *
 * We can't meaningfully unit-test `launchctl` load/unload in CI, so we lock down
 * the pure plist builder here and cover install/uninstall's file side effects.
 * Manual verification steps live in the module doc comment.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  buildLaunchAgentPlist,
  installService,
  uninstallService,
} from "./launchd.js";

test("plist embeds label, node+entry program args, and never auto-starts", () => {
  const xml = buildLaunchAgentPlist({
    label: "dev.pino",
    execPath: "/usr/bin/node",
    entry: "/opt/pino/index.js",
    logPath: "/home/u/.pino/pino.log",
  });
  assert.match(xml, /<key>Label<\/key>\s*<string>dev\.pino<\/string>/);
  assert.match(xml, /<string>\/usr\/bin\/node<\/string>/);
  assert.match(xml, /<string>\/opt\/pino\/index\.js<\/string>/);
  assert.match(xml, /<string>serve<\/string>/);
  // Opt-in only: must NOT run at load and must NOT be kept alive.
  assert.match(xml, /<key>RunAtLoad<\/key>\s*<false\/>/);
  assert.match(xml, /<key>KeepAlive<\/key>\s*<false\/>/);
  assert.match(xml, /<key>StandardOutPath<\/key>\s*<string>\/home\/u\/\.pino\/pino\.log<\/string>/);
});

test("plist escapes XML-special characters in paths", () => {
  const xml = buildLaunchAgentPlist({
    label: "dev.pino",
    execPath: "/usr/bin/node",
    entry: "/opt/a & b/index.js",
    logPath: "/l.log",
  });
  assert.match(xml, /a &amp; b/);
  assert.doesNotMatch(xml, /a & b/);
});

test("install writes the plist; uninstall removes it", () => {
  const dir = mkdtempSync(join(tmpdir(), "pino-plist-"));
  const plistPath = join(dir, "dev.pino.plist");
  installService({
    plistPath,
    label: "dev.pino",
    execPath: "/usr/bin/node",
    entry: "/opt/pino/index.js",
    logPath: "/l.log",
  });
  assert.equal(existsSync(plistPath), true);
  assert.match(readFileSync(plistPath, "utf8"), /dev\.pino/);

  const removed = uninstallService({ plistPath });
  assert.equal(removed, true);
  assert.equal(existsSync(plistPath), false);
  // Idempotent: removing again is a no-op that reports false.
  assert.equal(uninstallService({ plistPath }), false);

  rmSync(dir, { recursive: true, force: true });
});
