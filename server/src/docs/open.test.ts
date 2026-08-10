import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { openDocOnHost, type Spawn } from "./open.js";

function fixture(): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "makit-open-")));
  mkdirSync(join(root, "mockups"), { recursive: true });
  writeFileSync(join(root, "mockups", "board.html"), "<title>Board</title>");
  writeFileSync(join(root, ".env"), "SECRET=1\n");
  return root;
}

/** Records what would have been launched, and never launches anything. */
function recorder(err: Error | null = null): { spawn: Spawn; calls: Array<[string, string[]]> } {
  const calls: Array<[string, string[]]> = [];
  return {
    calls,
    spawn: (cmd, args, cb) => {
      calls.push([cmd, args]);
      cb(err);
    },
  };
}

test("opens a resolvable doc with the platform opener, passing the absolute path", async () => {
  const root = fixture();
  const rec = recorder();
  const result = await openDocOnHost(root, "mockups/board.html", {
    platform: "darwin",
    spawn: rec.spawn,
  });
  assert.equal(result.ok, true);
  assert.equal(rec.calls.length, 1);
  assert.equal(rec.calls[0]![0], "/usr/bin/open");
  assert.deepEqual(rec.calls[0]![1], [join(root, "mockups", "board.html")]);
});

test("linux uses xdg-open; windows uses cmd /c start with the empty title", async () => {
  const root = fixture();
  const lin = recorder();
  await openDocOnHost(root, "mockups/board.html", { platform: "linux", spawn: lin.spawn });
  assert.equal(lin.calls[0]![0], "xdg-open");

  const win = recorder();
  await openDocOnHost(root, "mockups/board.html", { platform: "win32", spawn: win.spawn });
  assert.equal(win.calls[0]![0], "cmd");
  assert.deepEqual(win.calls[0]![1].slice(0, 3), ["/c", "start", ""]);
});

// D2 is the one boundary: "open" must not become a way to launch anything the
// read path and the static route would have refused.
test("refuses what resolveDocPath refuses, and launches nothing", async () => {
  const root = fixture();
  for (const rel of [
    "../../etc/passwd",
    ".env",
    ".git/config",
    "mockups/../.env",
    "package.json",
    "node_modules/pkg/readme.md",
  ]) {
    const rec = recorder();
    const result = await openDocOnHost(root, rel, { platform: "darwin", spawn: rec.spawn });
    assert.equal(result.ok, false, `${rel} must be refused`);
    assert.equal(rec.calls.length, 0, `${rel} must not spawn an opener`);
  }
});

test("a path is passed as an argv element, never through a shell", async () => {
  const root = fixture();
  // A filename that would be catastrophic if it were ever concatenated into a
  // command string. It is a legitimate document (`.md`), so it DOES open — the
  // assertion is that it arrives as exactly one argv element and that the
  // embedded `;` command never ran.
  const nasty = 'a b; touch pwned.md';
  writeFileSync(join(root, "mockups", nasty), "# hi\n");
  const rec = recorder();
  const result = await openDocOnHost(root, `mockups/${nasty}`, {
    platform: "darwin",
    spawn: rec.spawn,
  });
  assert.equal(result.ok, true);
  assert.deepEqual(
    rec.calls[0]![1],
    [join(root, "mockups", nasty)],
    "the whole path must be one argv element",
  );
  assert.equal(
    existsSync(join(root, "pwned.md")),
    false,
    "the embedded command must not have run",
  );
});

test("a failing opener degrades loudly with the reason", async () => {
  const root = fixture();
  const rec = recorder(new Error("no such executable"));
  const result = await openDocOnHost(root, "mockups/board.html", {
    platform: "darwin",
    spawn: rec.spawn,
  });
  assert.equal(result.ok, false);
  assert.match(result.ok ? "" : result.reason, /no such executable/);
});
