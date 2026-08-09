import { test } from "node:test";
import assert from "node:assert/strict";
import { parseManifest, renderManifest } from "./handoff_manifest.js";

const FULL = {
  goal: "Make the migration idempotent",
  done: ["schema diff written", "test/migrate.test.ts covers the up path"],
  next: ["down path is unimplemented", "then run the full suite"],
  files: ["server/src/manager.ts:1361", "test/migrate.test.ts:88"],
  gotchas: ["resumeSessionPath is legacy; use resumeAgentSessionId"],
  openQuestions: ["do we need a lock during the backfill?"],
};

test("golden: a full manifest renders every section in the fixed order", () => {
  const out = renderManifest(parseManifest(FULL));
  assert.equal(
    out,
    [
      "## Goal",
      "",
      "Make the migration idempotent",
      "",
      "## Done",
      "",
      "- schema diff written",
      "- test/migrate.test.ts covers the up path",
      "",
      "## Next",
      "",
      "- down path is unimplemented",
      "- then run the full suite",
      "",
      "## Files",
      "",
      "- server/src/manager.ts:1361",
      "- test/migrate.test.ts:88",
      "",
      "## Gotchas",
      "",
      "- resumeSessionPath is legacy; use resumeAgentSessionId",
      "",
      "## Open questions",
      "",
      "- do we need a lock during the backfill?",
      "",
    ].join("\n"),
  );
});

test("golden: a partial manifest omits missing sections entirely (no empty headings)", () => {
  const out = renderManifest(parseManifest({ goal: "Ship it", next: ["write the test"] }));
  assert.equal(
    out,
    ["## Goal", "", "Ship it", "", "## Next", "", "- write the test", ""].join("\n"),
  );
});

test("golden: an empty manifest renders the empty string", () => {
  assert.equal(renderManifest(parseManifest({})), "");
});

test("unknown keys are dropped, not rejected", () => {
  const out = renderManifest(parseManifest({ goal: "keep me", nonsense: "drop me", foo: [1, 2] }));
  assert.equal(out, ["## Goal", "", "keep me", ""].join("\n"));
});

test("hostile shapes never throw and yield an empty manifest", () => {
  for (const bad of [null, undefined, 42, "a string", true, [], [1, 2, 3]]) {
    assert.doesNotThrow(() => parseManifest(bad));
    assert.equal(renderManifest(parseManifest(bad)), "");
  }
});

test("wrong element/field types are dropped, valid siblings survive", () => {
  const out = renderManifest(
    parseManifest({
      goal: ["not", "a", "string"], // wrong type → dropped
      done: "not an array", // wrong type → dropped
      next: ["ok", 1, null, "", "  ", "also ok"], // non-strings/blanks dropped
    }),
  );
  assert.equal(out, ["## Next", "", "- ok", "- also ok", ""].join("\n"));
});

test("a list that resolves to no valid entries omits its section", () => {
  assert.equal(renderManifest(parseManifest({ done: [1, null, ""] })), "");
});

test("goal that is blank or whitespace is omitted", () => {
  assert.equal(renderManifest(parseManifest({ goal: "   " })), "");
});
