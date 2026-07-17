import { test } from "node:test";
import assert from "node:assert/strict";

import { parseFieldValue, mapElicitation } from "./interaction.js";
import type { AskUser, UIResponse } from "../uicall.js";

test("parseFieldValue enforces the declared schema type", () => {
  // number: blank and non-numeric text reject; a clean number parses.
  assert.deepEqual(parseFieldValue("", "number"), { ok: false });
  assert.deepEqual(parseFieldValue("abc", "number"), { ok: false });
  assert.deepEqual(parseFieldValue("3.14", "number"), { ok: true, value: 3.14 });

  // integer: 1.5 is not an integer; a clean int parses.
  assert.deepEqual(parseFieldValue("1.5", "integer"), { ok: false });
  assert.deepEqual(parseFieldValue("", "integer"), { ok: false });
  assert.deepEqual(parseFieldValue("42", "integer"), { ok: true, value: 42 });

  // boolean: only exact truthy/falsy tokens; arbitrary text rejects.
  assert.deepEqual(parseFieldValue("yes", "boolean"), { ok: true, value: true });
  assert.deepEqual(parseFieldValue("no", "boolean"), { ok: true, value: false });
  assert.deepEqual(parseFieldValue("maybe", "boolean"), { ok: false });

  // string / untyped: accepted verbatim.
  assert.deepEqual(parseFieldValue("hello", "string"), { ok: true, value: "hello" });
  assert.deepEqual(parseFieldValue("hello", undefined), { ok: true, value: "hello" });
});

/** An askUser stub that always answers an input form with `value`. */
function inputAnswering(value: string): AskUser {
  return async (): Promise<UIResponse> => ({ kind: "input", value });
}

const schema = (type: string) => ({ properties: { n: { type } } });

test("mapElicitation declines a value that doesn't satisfy the field type", async () => {
  // Blank numeric input must NOT become 0 — it declines.
  const blank = await mapElicitation(
    { requestedSchema: schema("number") },
    inputAnswering(""),
    "s1",
  );
  assert.equal(blank.action, "decline");

  // 1.5 is not a valid integer → decline.
  const frac = await mapElicitation(
    { requestedSchema: schema("integer") },
    inputAnswering("1.5"),
    "s1",
  );
  assert.equal(frac.action, "decline");

  // Arbitrary text must NOT silently become `false` → decline.
  const bogusBool = await mapElicitation(
    { requestedSchema: schema("boolean") },
    inputAnswering("perhaps"),
    "s1",
  );
  assert.equal(bogusBool.action, "decline");
});

test("mapElicitation accepts a value that cleanly satisfies the field type", async () => {
  const num = await mapElicitation(
    { requestedSchema: schema("number") },
    inputAnswering("2.5"),
    "s1",
  );
  assert.deepEqual(num, { action: "accept", content: { n: 2.5 } });

  const bool = await mapElicitation(
    { requestedSchema: schema("boolean") },
    inputAnswering("true"),
    "s1",
  );
  assert.deepEqual(bool, { action: "accept", content: { n: true } });
});
