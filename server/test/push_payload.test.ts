import { test } from "node:test";
import assert from "node:assert/strict";

import {
  buildWakePayload,
  WAKE_ALERT_BODY,
  type ApnsPayload,
} from "../src/push/payload.js";

/** Collect every string value anywhere in the payload tree. */
function collectStrings(value: unknown, out: string[]): void {
  if (typeof value === "string") {
    out.push(value);
    return;
  }
  if (value && typeof value === "object") {
    for (const v of Object.values(value as Record<string, unknown>)) {
      collectStrings(v, out);
    }
  }
}

test("wake payload key set is allowlisted recursively", () => {
  const p: ApnsPayload = buildWakePayload({ pendingCount: 1 });

  // Top level: only `aps`.
  assert.deepEqual(Object.keys(p).sort(), ["aps"]);

  // aps: subset of the allowed keys — a new dynamic field fails this.
  const apsAllowed = new Set(["alert", "sound", "badge", "content-available"]);
  for (const k of Object.keys(p.aps)) {
    assert.ok(apsAllowed.has(k), `unexpected aps key: ${k}`);
  }

  // aps.alert: subset of {title, body}. A future `subtitle` is rejected here.
  const alertAllowed = new Set(["title", "body"]);
  for (const k of Object.keys(p.aps.alert)) {
    assert.ok(alertAllowed.has(k), `unexpected aps.alert key: ${k}`);
  }
});

test("wake payload contains no session content", () => {
  const probes = ["sess-123", "srv-999", "rm -rf /", "confirmAction", "What branch?"];
  // Build with a benign integer — no probe is ever in scope by construction.
  const p = buildWakePayload({ pendingCount: 7 });
  const strings: string[] = [];
  collectStrings(p, strings);
  for (const probe of probes) {
    for (const s of strings) {
      assert.ok(!s.includes(probe), `payload string "${s}" leaked probe "${probe}"`);
    }
  }
});

test("alert body is a fixed generic string", () => {
  assert.equal(buildWakePayload({ pendingCount: 0 }).aps.alert.body, WAKE_ALERT_BODY);
  assert.equal(buildWakePayload({ pendingCount: 99 }).aps.alert.body, WAKE_ALERT_BODY);
});

test("badge reflects pendingCount", () => {
  assert.equal(buildWakePayload({ pendingCount: 3 }).aps.badge, 3);
});
