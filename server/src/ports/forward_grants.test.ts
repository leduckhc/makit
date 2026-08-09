import assert from "node:assert/strict";
import { test } from "node:test";

import {
  FORWARD_IDLE_MS,
  FORWARD_TTL_MS,
  ForwardGrants,
} from "./forward_grants.js";

function grants(startAt = 1_000): { grants: ForwardGrants; advance: (ms: number) => void } {
  let now = startAt;
  return {
    grants: new ForwardGrants({ now: () => now }),
    advance: (ms) => {
      now += ms;
    },
  };
}

const TARGET = { deviceId: "dev-1", port: 5173, worktreePath: "/repo/wt-a" };

test("the TTL is 30 min and the idle reap is 60 s", () => {
  assert.equal(FORWARD_TTL_MS, 30 * 60_000);
  assert.equal(FORWARD_IDLE_MS, 60_000);
});

test("mint returns an unguessable id and a resolvable grant", () => {
  const h = grants();
  const a = h.grants.mint(TARGET);
  const b = h.grants.mint(TARGET);
  assert.notEqual(a.grantId, b.grantId);
  // 32 random bytes, base64url — long enough that the path segment is not a
  // guessable name, even though the bearer is what actually authenticates.
  assert.ok(a.grantId.length >= 40, `grantId too short: ${a.grantId}`);
  assert.match(a.grantId, /^[A-Za-z0-9_-]+$/, "URL-safe, so it needs no escaping");
  assert.equal(a.port, 5173);
  assert.equal(a.expiresAt, 1_000 + FORWARD_TTL_MS);
  assert.equal(h.grants.get(a.grantId, "dev-1")?.port, 5173);
});

test("a grant belongs to ONE device", () => {
  const h = grants();
  const g = h.grants.mint(TARGET);
  assert.equal(h.grants.get(g.grantId, "dev-2"), null, "another device may not use it");
  assert.equal(h.grants.get(g.grantId, undefined), null, "nor an unidentified caller");
  assert.equal(h.grants.get(g.grantId, "dev-1")?.grantId, g.grantId);
});

test("an unknown id resolves to null (never a throw)", () => {
  const h = grants();
  assert.equal(h.grants.get("nope", "dev-1"), null);
  assert.equal(h.grants.get("", "dev-1"), null);
});

test("the TTL is a hard cap — activity cannot extend it", () => {
  const h = grants();
  const g = h.grants.mint(TARGET);
  // Stay busy for the whole window: a forward the user forgot about must still
  // die on schedule (D3).
  for (let elapsed = 0; elapsed < FORWARD_TTL_MS; elapsed += 30_000) {
    h.advance(30_000);
    h.grants.get(g.grantId, "dev-1");
  }
  h.advance(1);
  assert.equal(h.grants.get(g.grantId, "dev-1"), null, "expired despite constant use");
});

test("an IDLE grant is reaped after FORWARD_IDLE_MS", () => {
  // "As long as the sheet stays open" cannot mean "until an explicit close": a
  // WebView keeps loading assets after the sheet is gone, and a `stop` can be
  // lost. Activity within the idle window is the operational definition.
  // Two grants, because resolving one REFRESHES its idle clock: checking the
  // near side and the far side on the same grant would only prove the refresh.
  const h = grants();
  const nearlyIdle = h.grants.mint(TARGET);
  h.advance(FORWARD_IDLE_MS - 1);
  assert.ok(h.grants.get(nearlyIdle.grantId, "dev-1"), "still fresh");

  const h2 = grants();
  const idle = h2.grants.mint(TARGET);
  h2.advance(FORWARD_IDLE_MS + 1);
  assert.equal(h2.grants.get(idle.grantId, "dev-1"), null, "idle too long");
});

test("each resolve refreshes the idle clock", () => {
  const h = grants();
  const g = h.grants.mint(TARGET);
  for (let i = 0; i < 5; i++) {
    h.advance(FORWARD_IDLE_MS - 1_000);
    assert.ok(h.grants.get(g.grantId, "dev-1"), `alive on hop ${i}`);
  }
});

test("stop revokes immediately, and only the owning device may stop it", () => {
  const h = grants();
  const g = h.grants.mint(TARGET);
  assert.equal(h.grants.stop(g.grantId, "dev-2"), false, "not yours to revoke");
  assert.ok(h.grants.get(g.grantId, "dev-1"));
  assert.equal(h.grants.stop(g.grantId, "dev-1"), true);
  assert.equal(h.grants.get(g.grantId, "dev-1"), null);
  assert.equal(h.grants.stop(g.grantId, "dev-1"), false, "already gone");
});

test("unpairing a device drops every grant it held", () => {
  const h = grants();
  const mine = h.grants.mint(TARGET);
  const theirs = h.grants.mint({ ...TARGET, deviceId: "dev-2" });
  h.grants.dropDevice("dev-1");
  assert.equal(h.grants.get(mine.grantId, "dev-1"), null);
  assert.ok(h.grants.get(theirs.grantId, "dev-2"), "another device is unaffected");
});

test("two devices get independent grants for the same port", () => {
  const h = grants();
  const a = h.grants.mint(TARGET);
  const b = h.grants.mint({ ...TARGET, deviceId: "dev-2" });
  h.grants.stop(a.grantId, "dev-1");
  assert.equal(h.grants.get(a.grantId, "dev-1"), null);
  assert.ok(h.grants.get(b.grantId, "dev-2"), "revoking one must not revoke the other");
});

test("expired grants are evicted, so the map cannot grow without bound", () => {
  const h = grants();
  for (let i = 0; i < 50; i++) h.grants.mint(TARGET);
  assert.equal(h.grants.size, 50);
  h.advance(FORWARD_TTL_MS + 1);
  h.grants.reap();
  assert.equal(h.grants.size, 0);
});

// ── browser-mode grants (the system-browser hand-off) ──────────────────────

test("a browser grant resolves WITHOUT a device id — the URL is the credential", () => {
  // A system browser cannot set an `Authorization` header, so for these grants
  // the unguessable id in the path IS the capability. Recorded as a flag rather
  // than inferred from "no bearer present", so the weaker mode is explicit in the
  // data and cannot be reached by accident.
  const h = grants();
  const g = h.grants.mint({ ...TARGET, browser: true });
  assert.equal(g.browser, true);
  assert.equal(h.grants.get(g.grantId, undefined)?.grantId, g.grantId);
  assert.equal(h.grants.get(g.grantId, "dev-9")?.grantId, g.grantId, "any holder of the URL");
});

test("browser mode does NOT weaken the TTL or the idle reap", () => {
  const h = grants();
  const g = h.grants.mint({ ...TARGET, browser: true });
  h.advance(FORWARD_IDLE_MS + 1);
  assert.equal(h.grants.get(g.grantId, undefined), null, "still idle-reaped");

  const h2 = grants();
  const g2 = h2.grants.mint({ ...TARGET, browser: true });
  for (let elapsed = 0; elapsed < FORWARD_TTL_MS; elapsed += 30_000) {
    h2.advance(30_000);
    h2.grants.get(g2.grantId, undefined);
  }
  h2.advance(1);
  assert.equal(h2.grants.get(g2.grantId, undefined), null, "still hard-capped");
});

test("a NON-browser grant still requires the owning device", () => {
  // The strict path must not be softened by the existence of the browser path.
  const h = grants();
  const g = h.grants.mint(TARGET);
  assert.equal(g.browser, false);
  assert.equal(h.grants.get(g.grantId, undefined), null);
  assert.equal(h.grants.get(g.grantId, "dev-9"), null);
});

test("stop revokes a browser grant from the device that minted it", () => {
  const h = grants();
  const g = h.grants.mint({ ...TARGET, browser: true });
  // Revocation stays device-bound even though *use* is not: the phone that asked
  // for the preview is the one that can end it.
  assert.equal(h.grants.stop(g.grantId, "dev-2"), false);
  assert.equal(h.grants.stop(g.grantId, "dev-1"), true);
  assert.equal(h.grants.get(g.grantId, undefined), null);
});
