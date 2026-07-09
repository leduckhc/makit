import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createPushSender } from "../src/push/config.js";
import type { ApnsConfig } from "../src/push/apns.js";

// -------- MINOR 2: graceful degradation on a corrupt .p8 -------------------

test("createPushSender(null) returns a disabled Noop sender", () => {
  const sender = createPushSender(null);
  assert.equal(sender.enabled, false);
});

test("createPushSender with a corrupt key degrades to a disabled sender (no throw)", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-apns-"));
  const keyPath = join(dir, "AuthKey_BAD.p8");
  // Not a valid EC private key — createPrivateKey() throws on this.
  writeFileSync(keyPath, "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----\n");
  const config: ApnsConfig = {
    keyPath,
    keyId: "ABC123",
    teamId: "TEAM456",
    bundleId: "dev.makit.app",
    env: "sandbox",
  };
  try {
    let sender!: ReturnType<typeof createPushSender>;
    assert.doesNotThrow(() => {
      sender = createPushSender(config);
    });
    assert.equal(sender.enabled, false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
