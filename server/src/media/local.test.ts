/**
 * Local-file media ingestion tests — the `![](…/shot.png)` case captured from a
 * real pi-acp turn (probe 2 of SPEC-22's wire survey), where the agent copied a
 * file and then referenced it by absolute path in its prose.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { MediaStore } from "./store.js";
import { LocalMediaResolver, rewriteMarkdownImages } from "./local.js";

const PNG = Buffer.from(
  "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c6300010000050001",
  "hex",
);

function fixture(opts: { maxBytes?: number } = {}) {
  const root = mkdtempSync(join(tmpdir(), "makit-local-ws-"));
  const outside = mkdtempSync(join(tmpdir(), "makit-local-out-"));
  const store = new MediaStore({ dir: join(root, ".store"), ...opts });
  const resolver = new LocalMediaResolver({ store, roots: [root] });
  writeFileSync(join(root, "shot.png"), PNG);
  writeFileSync(join(outside, "secret.png"), PNG);
  return { root, outside, store, resolver };
}

test("resolves an absolute path inside a root", () => {
  const { root, resolver } = fixture();
  const d = resolver.resolve(join(root, "shot.png"));
  assert.equal(d?.mime, "image/png");
  assert.equal(d?.sizeBytes, PNG.length);
});

test("resolves a file:// URL and a path relative to the first root", () => {
  const { root, resolver } = fixture();
  assert.notEqual(resolver.resolve(`file://${join(root, "shot.png")}`), null);
  assert.notEqual(resolver.resolve("shot.png"), null);
  assert.notEqual(resolver.resolve("./shot.png"), null);
});

test("refuses a path outside every root — including via traversal", () => {
  const { root, outside, resolver } = fixture();
  assert.equal(resolver.resolve(join(outside, "secret.png")), null);
  assert.equal(resolver.resolve(join(root, "..", "..", "etc", "hosts")), null);
  // A sibling directory whose name merely starts with the root's name.
  assert.equal(resolver.resolve(`${root}-evil/shot.png`), null);
});

test("refuses a symlink that escapes a root (realpath, not lexical, containment)", () => {
  const { root, outside, resolver } = fixture();
  symlinkSync(join(outside, "secret.png"), join(root, "link.png"));
  assert.equal(resolver.resolve(join(root, "link.png")), null);
});

test("refuses non-image extensions, unknown types, and directories", () => {
  const { root, resolver } = fixture();
  writeFileSync(join(root, "notes.txt"), "hi");
  writeFileSync(join(root, "run.sh"), "#!/bin/sh");
  writeFileSync(join(root, "vector.svg"), "<svg/>");
  mkdirSync(join(root, "adir.png"));
  assert.equal(resolver.resolve(join(root, "notes.txt")), null);
  assert.equal(resolver.resolve(join(root, "run.sh")), null);
  assert.equal(resolver.resolve(join(root, "vector.svg")), null, "SVG is script-bearing");
  assert.equal(resolver.resolve(join(root, "adir.png")), null);
  assert.equal(resolver.resolve(join(root, "missing.png")), null);
});

test("refuses a file over the size cap without reading it", () => {
  const { root, resolver } = fixture({ maxBytes: 8 });
  assert.equal(resolver.resolve(join(root, "shot.png")), null);
});

test("resolve() never throws on hostile input", () => {
  const { resolver } = fixture();
  for (const bad of ["", "   ", "http://x/y.png", "data:image/png;base64,AAA", "\u0000", "file://"]) {
    assert.equal(resolver.resolve(bad), null, JSON.stringify(bad));
  }
});

// ---- markdown rewrite ------------------------------------------------------

test("rewriteMarkdownImages swaps a resolved local path for a makit-media URI", () => {
  const text = "Copied to /tmp/out2.png — a gradient:\n\n![/tmp/out2.png](/tmp/out2.png)";
  const out = rewriteMarkdownImages(text, () => ({
    mediaId: "a".repeat(64),
    mime: "image/png",
    sizeBytes: 10,
  }));
  assert.equal(
    out,
    `Copied to /tmp/out2.png — a gradient:\n\n![/tmp/out2.png](makit-media:${"a".repeat(64)})`,
  );
});

test("rewriteMarkdownImages leaves remote, unresolvable and non-image markdown alone", () => {
  const cases = [
    "![x](https://example.com/a.png)",
    "![x](http://example.com/a.png)",
    "![x](/tmp/nope.png)", // resolver returns null
    "[a link](/tmp/out2.png)", // not an image
    "`![x](/tmp/out2.png)`", // inline code: not special-cased, but unresolvable
  ];
  const out = cases.map((c) =>
    rewriteMarkdownImages(c, (p) => (p === "/ok.png" ? { mediaId: "b".repeat(64), mime: "image/png", sizeBytes: 1 } : null)),
  );
  assert.deepEqual(out, cases);
});

test("rewriteMarkdownImages handles several images and is idempotent", () => {
  const resolve = () => ({ mediaId: "c".repeat(64), mime: "image/png", sizeBytes: 1 });
  const once = rewriteMarkdownImages("![a](/1.png) and ![b](/2.png)", resolve);
  assert.equal(once, `![a](makit-media:${"c".repeat(64)}) and ![b](makit-media:${"c".repeat(64)})`);
  // Re-running must not touch an already-rewritten URI.
  assert.equal(rewriteMarkdownImages(once, resolve), once);
});
