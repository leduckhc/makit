import { test } from "node:test";
import assert from "node:assert/strict";
import { resolve } from "node:path";

import { parseArgs } from "./serve.js";

test("parseArgs accepts a valid port and project", () => {
  const args = parseArgs(["--port", "9000", "--project", "/tmp/x"]);
  assert.equal(args.port, 9000);
  assert.deepEqual(args.projects, [resolve("/tmp/x")]);
});

test("parseArgs rejects a missing required value", () => {
  assert.throws(() => parseArgs(["--project"]), /missing value for --project/);
  assert.throws(() => parseArgs(["--port"]), /missing value for --port/);
  assert.throws(() => parseArgs(["--host"]), /missing value for --host/);
});

test("parseArgs rejects an out-of-range or non-numeric port", () => {
  assert.throws(() => parseArgs(["--port", "0"]), /invalid --port/);
  assert.throws(() => parseArgs(["--port", "70000"]), /invalid --port/);
  assert.throws(() => parseArgs(["--port", "abc"]), /invalid --port/);
  assert.throws(() => parseArgs(["--port", "8.5"]), /invalid --port/);
});
