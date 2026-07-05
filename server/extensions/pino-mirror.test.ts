/**
 * SPEC-05: pino-mirror sends spawnToken in host.open when PINO_SPAWN_TOKEN is
 * set in the environment; omits it otherwise.
 *
 * We test the pure extraction logic rather than the full WebSocket lifecycle.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { buildHostOpenFields } from "./pino-mirror-helpers.js";

test("buildHostOpenFields: includes spawnToken when env is set", () => {
  const fields = buildHostOpenFields({
    title: "my session",
    cwd: "/tmp/proj",
    spawnToken: "abc-123",
  });
  assert.equal(fields.kind, "host.open");
  assert.equal(fields.title, "my session");
  assert.equal(fields.cwd, "/tmp/proj");
  assert.equal(fields.spawnToken, "abc-123");
});

test("buildHostOpenFields: omits spawnToken when not provided", () => {
  const fields = buildHostOpenFields({ title: "no-token", cwd: "/tmp" });
  assert.equal(fields.kind, "host.open");
  assert.ok(!("spawnToken" in fields), "spawnToken must be absent when env not set");
});
