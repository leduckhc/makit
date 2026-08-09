import assert from "node:assert/strict";
import { test } from "node:test";

import { CommandRouter } from "../command_router.js";
import type { OutgoingFrame, WsClient } from "../client.js";
import type { CommandDeps, DocsCommandPort } from "./deps.js";
import { register as registerDocs } from "./docs.js";
import type { DocGrantDTO } from "../../protocol.js";

function fakeClient(overrides: Partial<WsClient> = {}): WsClient & { sent: OutgoingFrame[] } {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    send: (f) => sent.push(f),
    close: () => {},
    subscribed: new Set<string>(),
    authed: true,
    watchingMetrics: false,
    watchingPorts: false,
    watchingDocs: false,
    isLocal: true,
    ...overrides,
  };
}

const GRANT: DocGrantDTO = {
  grantId: "g1",
  worktreePath: "/wt",
  relPath: "mockups/board.html",
  url: "https://host.ts.net/docs/g1/mockups/board.html",
  reach: "tailnet",
  expiresAt: 123,
};

interface Recorder {
  router: CommandRouter;
  recounts: number;
  snapshotSends: WsClient[];
  docs: DocsCommandPort & { revoked: string[] };
}

function setup(docsOverrides: Partial<DocsCommandPort> = {}): Recorder {
  const revoked: string[] = [];
  const docs = {
    read: (_wt: string, rel: string) =>
      rel === "spec.md" ? { ok: true as const, text: "# hi" } : { ok: false as const, message: "nope" },
    publish: async (_wt: string, rel: string) =>
      rel === "mockups/board.html"
        ? { ok: true as const, grant: GRANT }
        : { ok: false as const, reason: "no reachable address" },
    unpublish: (grantId: string) => {
      revoked.push(grantId);
      return grantId === "g1";
    },
    grants: () => [GRANT],
    revoked,
    ...docsOverrides,
  } as DocsCommandPort & { revoked: string[] };

  const rec: Recorder = { router: new CommandRouter(), recounts: 0, snapshotSends: [], docs };
  const deps = {
    onDocsWatchersChanged: () => {
      rec.recounts++;
    },
    sendDocsSnapshot: (client: WsClient) => {
      rec.snapshotSends.push(client);
    },
    docs,
  } as unknown as CommandDeps;
  registerDocs(rec.router, deps);
  return rec;
}

const dispatch = (r: CommandRouter, c: WsClient, kind: string, env: Record<string, unknown> = {}) =>
  r.dispatch(c, { v: 1, t: "cmd", id: "1", kind, ...env } as never);

const acks = (c: WsClient) => (c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack");
const errs = (c: WsClient) => (c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "err");

// --- docs.watch mirrors ports.watch ---

test("docs.watch {on:true} acks, sets the flag, recounts, sends one snapshot", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, "docs.watch", { on: true });
  assert.equal(acks(c).length, 1);
  assert.equal(c.watchingDocs, true);
  assert.equal(rec.recounts, 1);
  assert.deepEqual(rec.snapshotSends, [c]);
});

test("a repeated docs.watch {on:true} does not re-send the snapshot", async () => {
  const rec = setup();
  const c = fakeClient({ watchingDocs: true });
  await dispatch(rec.router, c, "docs.watch", { on: true });
  assert.equal(rec.snapshotSends.length, 0);
});

test("docs.watch {on:false} clears the flag and recounts", async () => {
  const rec = setup();
  const c = fakeClient({ watchingDocs: true });
  await dispatch(rec.router, c, "docs.watch", { on: false });
  assert.equal(c.watchingDocs, false);
  assert.equal(rec.recounts, 1);
});

test('docs.watch with a malformed on is a no-op that never disarms a watcher', async () => {
  const rec = setup();
  const c = fakeClient({ watchingDocs: true });
  await dispatch(rec.router, c, "docs.watch", { on: "yes" });
  assert.equal(c.watchingDocs, true);
  assert.equal(rec.recounts, 0);
  assert.equal(acks(c).length, 1);
});

// --- docs.read ---

test("docs.read acks the text for a markdown doc", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, "docs.read", { worktreePath: "/wt", relPath: "spec.md" });
  const ack = acks(c)[0] as unknown as { text: string };
  assert.equal(ack.text, "# hi");
});

test("docs.read errs for a doc that cannot be read (e.g. html — D7)", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, "docs.read", { worktreePath: "/wt", relPath: "board.html" });
  assert.equal(errs(c).length, 1);
  assert.equal(acks(c).length, 0);
});

test("docs.read with a malformed payload errs, never throws", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, "docs.read", { worktreePath: 5 });
  assert.equal(errs(c).length, 1);
});

// --- docs.publish ---

test("docs.publish acks the grant on success", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, "docs.publish", { worktreePath: "/wt", relPath: "mockups/board.html" });
  const ack = acks(c)[0] as unknown as { grant: DocGrantDTO };
  assert.equal(ack.grant.grantId, "g1");
});

test("docs.publish errs with the stated reason when nothing is reachable (D15)", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, "docs.publish", { worktreePath: "/wt", relPath: "other.md" });
  assert.equal(errs(c).length, 1);
  assert.match((errs(c)[0] as unknown as { message: string }).message, /reachable/);
});

// --- docs.unpublish ---

test("docs.unpublish revokes the grant and acks", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, "docs.unpublish", { grantId: "g1" });
  assert.deepEqual(rec.docs.revoked, ["g1"]);
  assert.equal(acks(c).length, 1);
});

// --- docs.grants ---

test("docs.grants acks the current grant list", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, "docs.grants");
  const ack = acks(c)[0] as unknown as { grants: DocGrantDTO[] };
  assert.equal(ack.grants.length, 1);
  assert.equal(ack.grants[0]!.grantId, "g1");
});
