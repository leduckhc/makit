import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { readDocText, MAX_READ_BYTES } from "./read.js";

function fixture(): string {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "makit-docread-")));
  mkdirSync(join(root, "mockups"), { recursive: true });
  writeFileSync(join(root, "spec.md"), "# Spec\n\nbody\n");
  writeFileSync(join(root, "mockups", "board.html"), "<title>Board</title>");
  return root;
}

test("returns the text of a markdown document", () => {
  const r = readDocText(fixture(), "spec.md");
  assert.ok(r.ok);
  assert.equal(r.text, "# Spec\n\nbody\n");
});

test("errors for an html document (D7 — html is never sent over WSS)", () => {
  const r = readDocText(fixture(), "mockups/board.html");
  assert.equal(r.ok, false);
  assert.match(r.ok ? "" : r.message, /published, not read/);
});

test("errors for a document that does not resolve", () => {
  const r = readDocText(fixture(), "../../etc/passwd");
  assert.equal(r.ok, false);
  assert.match(r.ok ? "" : r.message, /escapes-root|absolute/);
});

test("errors for a markdown document over the 1 MB cap", () => {
  const root = fixture();
  writeFileSync(join(root, "big.md"), "x".repeat(MAX_READ_BYTES + 1));
  const r = readDocText(root, "big.md");
  assert.equal(r.ok, false);
});

test("reads a markdown document right at the cap", () => {
  const root = fixture();
  writeFileSync(join(root, "atcap.md"), "y".repeat(MAX_READ_BYTES));
  const r = readDocText(root, "atcap.md");
  assert.ok(r.ok);
  assert.equal(r.text.length, MAX_READ_BYTES);
});
