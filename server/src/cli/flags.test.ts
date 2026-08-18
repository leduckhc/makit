/**
 * The shared argv scanner (SPEC-cli-as-client). The behaviour that matters most is the one
 * the hand-written loops all got wrong: a value flag in last position.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { parseFlags, str, int, bool, list, type Spec } from "./flags.js";
import { captureCli } from "../../test/support/cli_home.js";

const SPEC: Spec = {
  host: { type: "string", def: "127.0.0.1" },
  port: { type: "int", def: 7777 },
  message: { type: "string", alias: "-m" },
  json: { type: "bool" },
  attach: { type: "list" },
  for: { type: "enum", values: ["idle", "approval", "input", "any"], def: "any" },
};

test("defaults apply when a flag is absent", () => {
  const p = parseFlags([], SPEC);
  assert.equal(str(p, "host"), "127.0.0.1");
  assert.equal(int(p, "port"), 7777);
  assert.equal(bool(p, "json"), false);
  assert.deepEqual(list(p, "attach"), []);
  assert.equal(str(p, "for"), "any");
  assert.equal(str(p, "message"), undefined);
});

test("values, aliases, repeats and positionals are all read", () => {
  const p = parseFlags(
    ["s1", "--port", "9", "-m", "hello", "--json", "--attach", "a.png", "--attach", "b.jpg", "tail"],
    SPEC,
  );
  assert.deepEqual(p.positionals, ["s1", "tail"], "in order, so `ask <id> <msg>` works");
  assert.equal(int(p, "port"), 9);
  assert.equal(str(p, "message"), "hello");
  assert.equal(bool(p, "json"), true);
  assert.deepEqual(list(p, "attach"), ["a.png", "b.jpg"]);
});

// ---------------------------------------------------------------------------
// The defect this module exists for
// ---------------------------------------------------------------------------

test("a value flag in last position is a usage error, not a read past the end", async () => {
  for (const argv of [["--port"], ["--host"], ["-m"], ["--attach"], ["--for"]]) {
    const r = await captureCli(async () => {
      parseFlags(argv, SPEC);
    });
    assert.equal(r.code, 2, `${argv[0]} with no value must exit 2, got ${r.code}`);
    assert.match(r.err, new RegExp(`\\${argv[0]}.*needs a value`));
  }
});

test("a non-numeric int is a usage error rather than NaN", async () => {
  const r = await captureCli(async () => {
    parseFlags(["--port", "abc"], SPEC);
  });
  assert.equal(r.code, 2);
  assert.match(r.err, /--port must be a number/);
});

test("an unknown enum value is refused, never widened to the default", async () => {
  // Silently falling back to `any` is the worst outcome: `wait --for aproval`
  // would exit 0 on a completed turn instead of blocking for a human.
  const r = await captureCli(async () => {
    parseFlags(["--for", "aproval"], SPEC);
  });
  assert.equal(r.code, 2);
  assert.match(r.err, /unknown --for value: aproval \(expected idle\|approval\|input\|any\)/);
});

test("unknown flags are ignored, because `run` parses one argv against two specs", () => {
  // Load-bearing, not laziness: parseRunArgs reads new's flags and wait's from
  // the same argv. Tightening this is a behaviour change, not a refactor.
  const p = parseFlags(["--not-a-flag", "value", "--port", "5"], SPEC);
  assert.equal(int(p, "port"), 5);
  assert.deepEqual(p.positionals, ["value"], "its value is loose, and reads as a positional");
});
