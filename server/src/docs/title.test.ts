import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { titleFromHtml, titleFromMarkdown, statusFromMarkdown, readDocMeta } from "./title.js";

/**
 * SPEC-46 D4 (the title is extracted, never the filename) and D14 (docStatus is
 * opportunistic and absent rather than guessed). Inputs below are the shapes
 * this repo actually writes.
 */

test("titleFromHtml takes the <title> element", () => {
  const html = `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8" />\n<title>makit — Ports: what's listening, and whose branch owns it (SPEC-41 draft)</title>`;
  assert.equal(
    titleFromHtml(html),
    "makit — Ports: what's listening, and whose branch owns it (SPEC-41 draft)",
  );
});

test("titleFromHtml collapses a title split across lines", () => {
  assert.equal(titleFromHtml("<title>one\n   two\n\tthree</title>"), "one two three");
});

test("titleFromHtml decodes the entities that actually appear in titles", () => {
  assert.equal(titleFromHtml("<title>A &amp; B &lt;C&gt; &quot;D&quot; &#39;E&#39; &nbsp;F</title>"), "A & B <C> \"D\" 'E' F");
});

test("titleFromHtml tolerates attributes and odd casing on the tag", () => {
  assert.equal(titleFromHtml('<TITLE dir="ltr">Board</TITLE>'), "Board");
});

test("titleFromHtml returns undefined when there is no title", () => {
  assert.equal(titleFromHtml("<html><body>no head</body></html>"), undefined);
  assert.equal(titleFromHtml("<title></title>"), undefined);
  assert.equal(titleFromHtml("<title>   </title>"), undefined);
});

test("titleFromMarkdown takes the first H1", () => {
  const md = "# SPEC-41 — Ports: what's listening, and whose branch owns it\n\n**Status:** Implemented\n";
  assert.equal(titleFromMarkdown(md), "SPEC-41 — Ports: what's listening, and whose branch owns it");
});

test("titleFromMarkdown finds an H1 that is not the first line", () => {
  assert.equal(titleFromMarkdown("\n\n<!-- a comment -->\n\n# Real Title\n"), "Real Title");
});

test("titleFromMarkdown skips YAML front matter", () => {
  const md = '---\nname: "a-skill"\ndescription: "not the title"\n---\n# The Title\n';
  assert.equal(titleFromMarkdown(md), "The Title");
});

test("titleFromMarkdown ignores a '#' inside a fenced code block", () => {
  const md = "```sh\n# not a heading\n```\n\n# Actual Heading\n";
  assert.equal(titleFromMarkdown(md), "Actual Heading");
});

test("titleFromMarkdown strips trailing hashes and inline markup", () => {
  assert.equal(titleFromMarkdown("# Title ###\n"), "Title");
  assert.equal(titleFromMarkdown("# `code` and **bold**\n"), "code and bold");
});

test("titleFromMarkdown prefers an H1 over an earlier H2", () => {
  assert.equal(titleFromMarkdown("## Preamble\n\n# The Real Title\n"), "The Real Title");
});

test("titleFromMarkdown falls back to the first H2 when a doc has no H1", () => {
  // docs/DEBUG-DESKTOP.md and DESIGN.md in this repo start at ## — a basename
  // like "DEBUG-DESKTOP.md" is strictly worse than the heading that is there.
  assert.equal(
    titleFromMarkdown("## Debug Mode: Desktop App on Worktree\n\nWhen developing…\n"),
    "Debug Mode: Desktop App on Worktree",
  );
  assert.equal(titleFromMarkdown("### Too deep\n"), undefined);
});

test("statusFromMarkdown reads the repo's front-matter line, shortened for a chip", () => {
  assert.equal(
    statusFromMarkdown("# T\n\n**Status:** Implemented (P1, rev 2) · **Priority:** P2 · **Branch:** `x`\n"),
    "Implemented",
  );
  assert.equal(statusFromMarkdown("# T\n\n**Status:** Draft (P1) · **Priority:** P2\n"), "Draft");
  assert.equal(statusFromMarkdown("# T\n\n**Status:** Draft\n"), "Draft");
});

test("statusFromMarkdown is absent rather than guessed (D14)", () => {
  assert.equal(statusFromMarkdown("# T\n\nJust prose about status.\n"), undefined);
  assert.equal(statusFromMarkdown("# T\n\n**Status:**\n"), undefined);
  assert.equal(statusFromMarkdown("# T\n\n**Priority:** P2\n"), undefined);
});

test("readDocMeta falls back to the basename when nothing is extractable", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-title-"));
  const p = join(dir, "untitled-board.html");
  writeFileSync(p, "<div>no title here</div>");
  assert.deepEqual(readDocMeta(p, "html"), { title: "untitled-board.html" });
});

test("readDocMeta reads title and status off a real markdown file", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-title-"));
  const p = join(dir, "2026-08-07-SPEC-44-ports-forward.md");
  writeFileSync(p, "# SPEC-44 — Ports P4\n\n**Status:** Draft · **Priority:** P3\n");
  assert.deepEqual(readDocMeta(p, "md"), { title: "SPEC-44 — Ports P4", docStatus: "Draft" });
});

test("readDocMeta does not read the whole file to find a title", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-title-"));
  const p = join(dir, "big.md");
  // A title at the top, then far more bytes than the read window.
  writeFileSync(p, "# Top Title\n" + "filler filler filler\n".repeat(200_000));
  assert.equal(readDocMeta(p, "md").title, "Top Title");
});

test("readDocMeta falls back to the basename on an unreadable file", () => {
  assert.deepEqual(readDocMeta("/nonexistent/path/gone.md", "md"), { title: "gone.md" });
});
