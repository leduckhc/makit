/**
 * Guards the recorded-session fixtures: every `test/fixtures/acp/<name>.events.json`
 * must be exactly what the CURRENT {@link AcpEventMapper} produces from the raw
 * `test/acp-sessions/<name>.jsonl` recording.
 *
 * The app replays these same files (app/test/acp_replay_test.dart) and cannot run
 * the TypeScript mapper, so without this check a mapper change would silently
 * leave the app asserting stale wire behavior. Regenerate with:
 *   node_modules/.bin/tsx test/replay-acp-session.ts --write
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import assert from "node:assert/strict";
import test from "node:test";
import { fixtureDirs, renderFixture, sessionNames } from "./replay-acp-session.js";

const names = sessionNames();

test("there is at least one recorded ACP session", () => {
  assert.ok(names.length > 0, "no *.jsonl recordings in test/acp-sessions");
});

for (const name of names) {
  test(`${name}.events.json matches a fresh replay of ${name}.jsonl`, () => {
    const expected = renderFixture(name);
    for (const dir of fixtureDirs) {
      const path = join(dir, `${name}.events.json`);
      assert.equal(
        readFileSync(path, "utf8"),
        expected,
        `${path} is stale — regenerate with: node_modules/.bin/tsx test/replay-acp-session.ts --write`,
      );
    }
  });
}
