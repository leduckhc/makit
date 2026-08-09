import assert from "node:assert/strict";
import { test } from "node:test";

import { changedPaths } from "./changed.js";
import type { Exec } from "./changed.js";

/** An {@link Exec} that answers the merge-base diff with `stdout`, exit `code`. */
function fakeExec(code: number, stdout: string): { exec: Exec; calls: string[][] } {
  const calls: string[][] = [];
  const exec: Exec = async (_cmd, args) => {
    calls.push(args);
    return { code, stdout, stderr: "" };
  };
  return { exec, calls };
}

test("returns the set of files that differ from the merge base", async () => {
  const { exec, calls } = fakeExec(0, "docs/a.md\nmockups/b.html\n");
  const changed = await changedPaths("/wt", "main", "feat/x", exec);
  assert.deepEqual([...changed!].sort(), ["docs/a.md", "mockups/b.html"]);
  // Three-dot syntax IS the merge-base diff the +/- badge already uses (D5).
  assert.deepEqual(calls[0], ["diff", "--name-only", "main...HEAD"]);
});

test("on the base branch, nothing differs from the merge base (empty, not absent)", async () => {
  // git must not even be consulted: HEAD *is* the merge base with itself.
  const { exec, calls } = fakeExec(0, "should-not-be-read");
  const changed = await changedPaths("/wt", "main", "main", exec);
  assert.deepEqual([...changed!], []);
  assert.equal(calls.length, 0, "no git ran on the base branch");
});

test("with no base branch, changed is undetermined (absent), never false-for-all", async () => {
  const { exec } = fakeExec(0, "");
  const changed = await changedPaths("/wt", null, "feat/x", exec);
  assert.equal(changed, undefined);
});

test("a non-zero git exit is UNDETERMINED (absent), not 'nothing changed'", async () => {
  // git.ts run() resolves a missing binary / spawn fault as {code:127}: the trap
  // is treating that as an empty diff. It must read as undetermined instead.
  const { exec } = fakeExec(127, "");
  const changed = await changedPaths("/wt", "main", "feat/x", exec);
  assert.equal(changed, undefined, "code:127 must not collapse to 'nothing changed'");
});

test("an empty diff on a feature branch is determined-empty (not undetermined)", async () => {
  const { exec } = fakeExec(0, "\n");
  const changed = await changedPaths("/wt", "main", "feat/x", exec);
  assert.deepEqual([...changed!], []);
});
