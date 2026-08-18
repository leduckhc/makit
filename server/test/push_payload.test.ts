import { test } from "node:test";
import assert from "node:assert/strict";

import {
  buildPortDownPayload,
  buildWakePayload,
  WAKE_ALERT_BODY,
  WAKE_ALERT_TITLE,
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

/**
 * Allowlisted key set at every dictionary path. Any object node whose path is
 * absent here, or which carries a key not in its set, fails the walk — so a
 * forbidden key at ANY depth (e.g. a future `aps.alert.subtitle`) is caught.
 */
const ALLOWED_KEYS: Record<string, Set<string>> = {
  "": new Set(["aps"]),
  aps: new Set(["alert", "sound", "badge", "content-available"]),
  "aps.alert": new Set(["title", "body"]),
};

/** Recursively assert every object-valued node contains only allowlisted keys. */
function assertKeysAllowlisted(value: unknown, path: string): void {
  if (!value || typeof value !== "object") return;
  const allowed = ALLOWED_KEYS[path];
  assert.ok(allowed, `unexpected object node at path "${path || "<root>"}"`);
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    assert.ok(allowed!.has(k), `unexpected key "${k}" at path "${path || "<root>"}"`);
    assertKeysAllowlisted(v, path ? `${path}.${k}` : k);
  }
}

test("wake payload key set is allowlisted recursively", () => {
  const p: ApnsPayload = buildWakePayload({ pendingCount: 1 });
  // A single recursive traversal: every object node must live at a known path
  // and expose only allowlisted keys, at any depth.
  assertKeysAllowlisted(p, "");
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

// ── SPEC-ports-forward D8: the port-down alert ────────────────────────────────────────

test("the port-down alert names the port and NOTHING else", () => {
  // The signature is the invariant, exactly as for the wake payload: only an
  // integer is in scope, so a branch, a path or a command CANNOT appear on a lock
  // screen. This test pins the shape as well as the strings.
  const p = buildPortDownPayload({ port: 5173 });
  // The same recursive allowlist the wake payload is held to: a future field
  // (`aps.alert.subtitle`, a `data` bag) fails here instead of shipping.
  assertKeysAllowlisted(p, "");
  assert.equal(p.aps.alert.title, WAKE_ALERT_TITLE);
  assert.equal(p.aps.alert.body, ":5173 stopped listening");
  assert.equal(
    p.aps.badge,
    undefined,
    "no badge: APNs treats 0 as CLEAR, which would wipe a waiting turn's count",
  );
  assert.equal(p.aps["content-available"], 1);

  const strings: string[] = [];
  collectStrings(p, strings);
  for (const probe of ["feat/", "/Users/", "vite", "sess-"]) {
    for (const s of strings) {
      assert.ok(!s.includes(probe), `payload string "${s}" leaked "${probe}"`);
    }
  }
});
