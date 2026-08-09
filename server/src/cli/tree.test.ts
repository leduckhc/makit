/**
 * U1 (SPEC-46 P2) — `makit tree`: the spawn tree as a projection of D10's
 * lineage.
 *
 * P1 made sessions appear by themselves: an agent that runs out of context hands
 * its work to a fresh session. `tree` is how a human sees what happened — who
 * spawned whom and why — and it needs no new wire at all, because `parentId`,
 * `handoffReason` and `origin` already ride on `SessionDTO` (D10).
 *
 * The hostile cases are the interesting ones. Lineage is persisted data, so a
 * crash mid-write or a hand-edited database can hand the *client* a cycle or a
 * dangling parent — the same reason T11's server-side walk terminates on both.
 * A renderer that recursed naively would hang the terminal instead.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { renderTree } from "./tree.js";
import type { SessionDTO } from "../protocol.js";

const s = (over: Partial<SessionDTO> & { id: string }): SessionDTO =>
  ({
    projectId: "p1",
    agent: "pi",
    title: over.id,
    status: "idle",
    policy: "ask-on-risky",
    lastActivityAt: 0,
    lastPreview: "",
    queued: [],
    pending: false,
    resumable: false,
    archived: false,
    ...over,
  }) as SessionDTO;

test("a root with no children is one line", () => {
  const out = renderTree([s({ id: "a", title: "alone" })]);
  assert.equal(out.trimEnd(), "a  [idle]  alone");
});

test("children are indented under their parent, in snapshot order", () => {
  const out = renderTree([
    s({ id: "root", title: "the original" }),
    s({ id: "kid", title: "the handoff", parentId: "root" }),
    s({ id: "grandkid", title: "deeper", parentId: "kid" }),
  ]);
  const lines = out.trimEnd().split("\n");
  assert.equal(lines.length, 3);
  assert.match(lines[0]!, /^root /);
  assert.match(lines[1]!, /^  .*kid/);
  assert.match(lines[2]!, /^ {4}.*grandkid/);
});

test("the handoff reason and a non-app origin are shown — that is the whole point", () => {
  const out = renderTree([
    s({ id: "root" }),
    s({ id: "kid", parentId: "root", handoffReason: "out of context", origin: "agent" }),
  ]);
  assert.match(out, /out of context/);
  assert.match(out, /agent/);
});

test("a session born on the phone says nothing about its origin", () => {
  // Most sessions are app-born; labelling every one of them is noise.
  const out = renderTree([s({ id: "root", origin: "app" })]);
  assert.doesNotMatch(out, /app/);
});

test("an orphan renders at the root rather than vanishing", () => {
  // The parent may be archived, or killed, or simply not in this snapshot. A
  // session that silently disappears from `tree` is worse than one shown flat.
  const out = renderTree([s({ id: "orphan", parentId: "long-gone", handoffReason: "why" })]);
  assert.match(out, /orphan/);
  assert.match(out, /long-gone/, "and it says which parent it lost");
});

test("a forged parentId cycle terminates instead of hanging the terminal", () => {
  // Hostile persisted data reaches the client too (T11 guards the server side).
  const out = renderTree([
    s({ id: "a", parentId: "b" }),
    s({ id: "b", parentId: "a" }),
  ]);
  const lines = out.trimEnd().split("\n");
  assert.equal(lines.length, 2, "each session appears exactly once");
  assert.match(out, /a/);
  assert.match(out, /b/);
});

test("a session that is its own parent renders once", () => {
  const out = renderTree([s({ id: "self", parentId: "self" })]);
  assert.equal(out.trimEnd().split("\n").length, 1);
});

test("every session in the snapshot appears exactly once, whatever the shape", () => {
  const sessions = [
    s({ id: "r1" }),
    s({ id: "c1", parentId: "r1" }),
    s({ id: "c2", parentId: "r1" }),
    s({ id: "x", parentId: "y" }),
    s({ id: "y", parentId: "x" }),
    s({ id: "lonely" }),
  ];
  const out = renderTree(sessions);
  for (const one of sessions) {
    const hits = out.split("\n").filter((l) => l.includes(one.id)).length;
    assert.ok(hits >= 1, `${one.id} is present`);
  }
  assert.equal(out.trimEnd().split("\n").length, sessions.length);
});
