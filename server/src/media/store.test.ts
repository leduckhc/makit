/**
 * MediaStore tests — content-addressed blob store for assistant display media
 * (SPEC-assistant-display-media). Every test uses a temp `MAKIT_HOME` so nothing touches `~/.makit`.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";

import { MediaStore, MEDIA_MIME_ALLOWLIST } from "./store.js";

const png = Buffer.from(
  "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c6300010000050001",
  "hex",
);

function store(opts: { maxBytes?: number } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "makit-media-"));
  return { dir, s: new MediaStore({ dir, ...opts }) };
}

test("put() writes the blob content-addressed by sha256 and returns a descriptor", () => {
  const { dir, s } = store();
  const d = s.put(png, "image/png");

  assert.equal(d.mediaId, createHash("sha256").update(png).digest("hex"));
  assert.equal(d.mime, "image/png");
  assert.equal(d.sizeBytes, png.length);
  assert.deepEqual(readFileSync(join(dir, d.mediaId)), png);
});

test("put() is idempotent — the same bytes dedupe to one blob", () => {
  const { dir, s } = store();
  const a = s.put(png, "image/png");
  const b = s.put(png, "image/png");

  assert.equal(a.mediaId, b.mediaId);
  // One blob + one sidecar, not two of each.
  assert.deepEqual(readdirSync(dir).sort(), [a.mediaId, `${a.mediaId}.json`].sort());
});

test("put() leaves no temp files behind (atomic publish)", () => {
  const { dir, s } = store();
  s.put(png, "image/png");
  assert.equal(
    readdirSync(dir).some((f) => f.includes(".tmp")),
    false,
  );
});

test("putBase64() decodes, and rejects a payload over the cap BEFORE writing", () => {
  const { dir, s } = store({ maxBytes: 64 });
  const ok = s.putBase64(png.toString("base64"), "image/png");
  assert.notEqual(ok, null);

  const tooBig = s.putBase64(Buffer.alloc(128, 7).toString("base64"), "image/png");
  assert.equal(tooBig, null, "oversized payload is refused");
  assert.equal(readdirSync(dir).length, 2, "nothing written for the refused payload");
});

test("putBase64() rejects a mime outside the allowlist and malformed base64", () => {
  const { s } = store();
  assert.equal(s.putBase64(png.toString("base64"), "text/html"), null);
  assert.equal(s.putBase64(png.toString("base64"), "application/x-sh"), null);
  assert.equal(s.putBase64("!!!not base64!!!", "image/png"), null);
  // The allowlist is the single source of truth for what may be served.
  assert.ok(MEDIA_MIME_ALLOWLIST.has("image/png"));
  assert.ok(MEDIA_MIME_ALLOWLIST.has("image/gif"));
  assert.ok(!MEDIA_MIME_ALLOWLIST.has("image/svg+xml"), "SVG is script-bearing — not allowed");
});

test("stat() returns the descriptor for a stored id and null otherwise", () => {
  const { s } = store();
  const d = s.put(png, "image/png");

  const got = s.stat(d.mediaId);
  assert.deepEqual(got, { mediaId: d.mediaId, mime: "image/png", sizeBytes: png.length });
  assert.equal(s.stat("f".repeat(64)), null, "unknown id → null (route turns this into 404)");
});

test("stat() rejects anything that is not a bare sha256 (path traversal)", () => {
  const { dir, s } = store();
  writeFileSync(join(dir, "secret"), "boom");
  for (const bad of ["../secret", "secret", "..", "", "ABC", "a".repeat(63), `${"a".repeat(64)}.json`]) {
    assert.equal(s.stat(bad), null, `must reject ${JSON.stringify(bad)}`);
  }
});

test("a corrupt/missing sidecar makes the blob unservable rather than guessing a mime", () => {
  const { dir, s } = store();
  const d = s.put(png, "image/png");
  writeFileSync(join(dir, `${d.mediaId}.json`), "{not json");
  assert.equal(s.stat(d.mediaId), null);
});
