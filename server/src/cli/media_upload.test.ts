/**
 * SPEC-user-attachments/46 — the `--attach` upload leg.
 *
 * The media POST is the one part of a CLI verb that does not ride the WebSocket,
 * so it needs its own teardown discipline: `client.close()` cannot rescue a
 * dangling HTTPS request. An upload that never settles keeps the event loop
 * alive and the verb never reaches an exit code at all — for a contract built on
 * exit codes (D8) that is the single outcome a caller cannot handle.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { uploadMedia, UPLOAD_TIMEOUT_MS } from "./media_upload.js";
import { startStubWss } from "../../test/support/stub_wss.js";

const target = (port: number) => ({ host: "127.0.0.1", port, bearer: "CACHED" });
const png = Buffer.from([0x89, 0x50, 0x4e, 0x47]);

test("a successful upload resolves with the server's mediaId", async () => {
  const stub = await startStubWss({ acceptBearer: "CACHED", mediaId: "abc123" });
  try {
    const id = await uploadMedia(target(stub.port), "/tmp/shot.png", png, "image/png");
    assert.equal(id, "abc123");
    assert.equal(stub.uploads[0]!.auth, "Bearer CACHED");
  } finally {
    await stub.close();
  }
});

test("an upload the server accepts and never answers rejects instead of hanging", async () => {
  const stub = await startStubWss({ acceptBearer: "CACHED", mediaStall: true });
  try {
    const started = Date.now();
    await assert.rejects(
      uploadMedia(target(stub.port), "/tmp/shot.png", png, "image/png", 150),
      (e: Error) => {
        assert.match(e.message, /shot\.png/, "the failure names the file");
        assert.match(e.message, /timed out/i);
        return true;
      },
    );
    assert.ok(Date.now() - started < 5_000, "the timeout must actually fire");
    assert.equal(stub.uploads.length, 1, "the upload was genuinely attempted");
  } finally {
    await stub.close();
  }
});

test("a refused upload keeps reporting the server's status, not a timeout", async () => {
  // mediaId unset → the stub answers 415. The timeout must not mask a real answer.
  const stub = await startStubWss({ acceptBearer: "CACHED" });
  try {
    await assert.rejects(
      uploadMedia(target(stub.port), "/tmp/shot.png", png, "image/png", 5_000),
      /refused \(415\)/,
    );
  } finally {
    await stub.close();
  }
});

test("the default timeout is generous enough for a real upload, but finite", () => {
  assert.ok(UPLOAD_TIMEOUT_MS >= 10_000, "a large attachment on a slow link must not be cut off");
  assert.ok(Number.isFinite(UPLOAD_TIMEOUT_MS), "but it must exist at all");
});
