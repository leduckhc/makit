/**
 * `parseAttachments` (SPEC-33 §3.3) — the boundary between the wire's
 * `attachments` array and descriptors an adapter can actually deliver.
 *
 * Its result is a discriminated union rather than a value-or-marker: "nothing
 * attached", "here they are", "you named one we no longer have" and "too many"
 * are four different outcomes, and two of them are user-facing refusals.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { MediaStore } from "../../media/store.js";
import { MAX_ATTACHMENTS, parseAttachments } from "./session.js";

const png = Buffer.from("89504e470d0a1a0a-not-a-real-png", "utf8");
const absent = "f".repeat(64);

function storeWithPng(): { store: MediaStore; mediaId: string } {
  const store = new MediaStore({ dir: mkdtempSync(join(tmpdir(), "makit-parse-")) });
  return { store, mediaId: store.put(png, "image/png").mediaId };
}

test("no attachments key → ok with nothing attached", () => {
  const { store } = storeWithPng();
  const parsed = parseAttachments(undefined, store);
  assert.deepEqual(parsed, { ok: true });
});

test("a stored id resolves to a descriptor, carrying the display name", () => {
  const { store, mediaId } = storeWithPng();
  const parsed = parseAttachments([{ mediaId, name: "shot.png" }], store);
  assert.equal(parsed.ok, true);
  assert.equal(parsed.attachments?.length, 1);
  assert.equal(parsed.attachments?.[0].mediaId, mediaId);
  assert.equal(parsed.attachments?.[0].name, "shot.png");
});

test("malformed entries are dropped, the well-formed remainder survives", () => {
  // A client sending junk gets the rest of its turn, matching parseConfigPicks.
  const { store, mediaId } = storeWithPng();
  const parsed = parseAttachments(
    [null, 42, {}, { mediaId: "not-a-hash" }, { mediaId: mediaId.toUpperCase() }, { mediaId }],
    store,
  );
  assert.equal(parsed.ok, true);
  assert.equal(parsed.attachments?.length, 1);
});

test("an id the store cannot resolve is a refusal, not a silent drop", () => {
  // Dropping it would turn "why is this misaligned?" into a bare text prompt and
  // leave the user reading a reply about nothing.
  const { store } = storeWithPng();
  assert.deepEqual(parseAttachments([{ mediaId: absent }], store), {
    ok: false,
    reason: "unresolved",
  });
});

test("more than the per-message cap is a refusal", () => {
  const { store, mediaId } = storeWithPng();
  const many = Array.from({ length: MAX_ATTACHMENTS + 1 }, () => ({ mediaId }));
  assert.deepEqual(parseAttachments(many, store), { ok: false, reason: "too_many" });
});

test("the cap itself is allowed", () => {
  const { store, mediaId } = storeWithPng();
  const exactly = Array.from({ length: MAX_ATTACHMENTS }, () => ({ mediaId }));
  const parsed = parseAttachments(exactly, store);
  assert.equal(parsed.ok, true);
  assert.equal(parsed.attachments?.length, MAX_ATTACHMENTS);
});
