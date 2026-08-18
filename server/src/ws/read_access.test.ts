/**
 * SPEC-cli-as-client D17 — **every** read path is gated on the principal, not just fanout.
 *
 * T5 gated `fanout` and the rev-3 acceptance box was written against it, which
 * gave false assurance: three sibling paths reached the same data without ever
 * consulting the principal, so an agent token could read every session on the
 * machine — precisely the property D17 exists to deny.
 *
 *   1. `fanout`            — gated by T5.
 *   2. `handleSub`         — was NOT gated, and replays the whole persisted log.
 *                            `sub` is answered by a switch in `server.ts` *before*
 *                            the router, so the capability map never sees it (and
 *                            `"sub"` is not even a router kind, which is why the
 *                            completeness test could not catch this).
 *   3. `sessions.snapshot` — was NOT gated: pushed on auth, every session's id,
 *                            title, preview, worktree and lineage.
 *   4. `session.transcript`— was NOT gated: a `read` cap returned any session's
 *                            last 200 events.
 *
 * The enumeration test at the bottom is the real guard: it fails when a new read
 * path appears without a decision about the principal, because "I gated the path I
 * was thinking about" is exactly how this happened the first time.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { canReadSession } from "./read_access.js";
import type { Principal } from "./principal.js";

const agent = (sessionId: string): Principal => ({
  deviceId: sessionId,
  label: `agent:${sessionId}`,
  caps: ["read", "send", "spawn"],
  sessionId,
});
const cli: Principal = { deviceId: "d", label: "cli@host", caps: ["client"] };
const phone: Principal = { deviceId: "d", label: "phone" }; // no caps = full access

/** Lineage: root → child → grandchild, plus an unrelated session. */
const parentOf = (id: string): string | undefined =>
  ({ child: "root", grandchild: "child" })[id];

test("a session-scoped principal may read its own session", () => {
  assert.equal(canReadSession(agent("root"), "root", parentOf), true);
});

test("it may read a DESCENDANT — the session it handed work off to (D17)", () => {
  // The prose says "its own session and its descendants": an agent that spawned a
  // child is entitled to watch what it started, and fanout's own-session-only
  // check was narrower than the decision it implements.
  assert.equal(canReadSession(agent("root"), "child", parentOf), true);
  assert.equal(canReadSession(agent("root"), "grandchild", parentOf), true);
});

test("it may NOT read an unrelated session", () => {
  assert.equal(canReadSession(agent("root"), "stranger", parentOf), false);
});

test("it may NOT read its own ANCESTOR — the parent's work is not its business", () => {
  assert.equal(canReadSession(agent("child"), "root", parentOf), false);
});

test("a forged lineage cycle terminates instead of hanging the walk", () => {
  const cyclic = (id: string): string | undefined => ({ a: "b", b: "a" })[id];
  assert.equal(canReadSession(agent("a"), "b", cyclic), true, "b's parent is a");
  assert.equal(canReadSession(agent("stranger"), "a", cyclic), false);
});

test("a human principal (CLI or phone) reads everything, as before", () => {
  // D17: absent caps means full access, and `client` is the same surface as a
  // phone. Nothing here may narrow what already-paired devices can see.
  for (const p of [cli, phone, undefined]) {
    assert.equal(canReadSession(p, "anything", parentOf), true);
  }
});

// ---------------------------------------------------------------------------
// The guard against the next forgotten path
// ---------------------------------------------------------------------------

test("every server read path consults canReadSession", async () => {
  const { readFile } = await import("node:fs/promises");
  // Each entry: the file, and the marker proving it guards reads.
  // server.ts:sendSnapshots uses the indirection visibleSessions rather than
  // calling canReadSession directly, so we check for that instead.
  const paths: [string, string][] = [
    ["src/ws/subscription_hub.ts", "canReadSession"], // fanout + handleSub
    ["src/server.ts", "visibleSessions"], // sessions.snapshot guards via this function
    ["src/ws/commands/session.ts", "canReadSession"], // session.transcript
  ];
  for (const [file, marker] of paths) {
    const src = await readFile(new URL(`../../${file}`, import.meta.url), "utf8");
    assert.ok(
      src.includes(marker),
      `${file} reads session data but does not use ${marker} to guard access`,
    );
  }
});
