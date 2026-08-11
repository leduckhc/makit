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
    isIndexedWorktree: (wt: string) => wt === "/wt",
    read: (_wt: string, rel: string) =>
      rel === "spec.md" ? { ok: true as const, text: "# hi" } : { ok: false as const, message: "nope" },
    publish: async (_wt: string, rel: string) =>
      rel === "mockups/board.html"
        ? { ok: true as const, grant: GRANT }
        : { ok: false as const, reason: "no reachable address" },
    open: async () => ({ ok: false as const, reason: "stub" }),
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

// --- docs.open ---

test("docs.open acks for a local client, handed to the OS opener", async () => {
  const rec = setup();
  let openedPath = "";
  const c = fakeClient({
    isLocal: true,
  });
  rec.docs.open = async (wt: string, rel: string) => {
    openedPath = `${wt}:${rel}`;
    return { ok: true, absPath: `${wt}/${rel}` };
  };
  await dispatch(rec.router, c, "docs.open", { worktreePath: "/wt", relPath: "mockups/board.html" });
  assert.equal(openedPath, "/wt:mockups/board.html");
  assert.equal(acks(c).length, 1);
});

test("docs.open errs for a remote (non-local) client", async () => {
  const rec = setup();
  const c = fakeClient({ isLocal: false });
  await dispatch(rec.router, c, "docs.open", { worktreePath: "/wt", relPath: "mockups/board.html" });
  assert.equal(errs(c).length, 1);
  assert.match((errs(c)[0] as unknown as { message: string }).message, /local/);
});

// The first cut answered every failure with "could not open document", which
// tells the user nothing and breaks the house rule publish already follows:
// degrade loudly, with the reason. A refused path must say it was refused.
test("docs.open errs with the opener's stated reason, not a bare failure", async () => {
  const rec = setup();
  const c = fakeClient({ isLocal: true });
  rec.docs.open = async () => ({ ok: false, reason: "cannot open .env: dotfile" });
  await dispatch(rec.router, c, "docs.open", { worktreePath: "/wt", relPath: ".env" });
  assert.equal(acks(c).length, 0, "a refusal must not ack");
  assert.match((errs(c)[0] as unknown as { message: string }).message, /dotfile/);
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

// --- scoping of client-supplied identifiers (SPEC-44 owner model) ---

// A worktreePath the index never reported must be refused before it reaches the
// filesystem — type-checking the value is not the same as trusting it.
for (const kind of ["docs.read", "docs.publish", "docs.open"]) {
  test(`${kind} refuses a worktreePath the index never reported`, async () => {
    const rec = setup();
    const c = fakeClient({ isLocal: true });
    await dispatch(rec.router, c, kind, { worktreePath: "/not-indexed", relPath: "spec.md" });
    assert.equal(acks(c).length, 0, "an unknown worktree must not be served");
    assert.equal(errs(c).length, 1);
    assert.match((errs(c)[0] as unknown as { message: string }).message, /indexed worktree/);
  });
}

test("docs.publish records the caller's deviceId as the grant owner", async () => {
  let owner: string | undefined = "unset";
  const rec = setup({
    publish: async (_wt: string, _rel: string, ownerDeviceId?: string) => {
      owner = ownerDeviceId;
      return { ok: true as const, grant: GRANT };
    },
  });
  const c = fakeClient({ deviceId: "dev-7" });
  await dispatch(rec.router, c, "docs.publish", { worktreePath: "/wt", relPath: "mockups/board.html" });
  assert.equal(owner, "dev-7", "publish must be scoped to the minting device");
});

test("docs.grants is scoped to the caller's deviceId", async () => {
  let owner: string | undefined = "unset";
  const rec = setup({
    grants: (ownerDeviceId?: string) => {
      owner = ownerDeviceId;
      return [];
    },
  });
  const c = fakeClient({ deviceId: "dev-9" });
  await dispatch(rec.router, c, "docs.grants");
  assert.equal(owner, "dev-9", "a client may only enumerate its own shares");
});

// The refusal of a foreign grant must be indistinguishable from an unknown id:
// both pass the caller's deviceId to the store (which no-ops) and both still
// ack {ok}, so unpublish cannot probe whether another device holds an id.
test("docs.unpublish scopes to the caller and acks {ok} either way", async () => {
  let seen: { grantId: string; owner: string | undefined } | null = null;
  const rec = setup({
    unpublish: (grantId: string, ownerDeviceId?: string) => {
      seen = { grantId, owner: ownerDeviceId };
      return false; // foreign/unknown — nothing removed
    },
  });
  const c = fakeClient({ deviceId: "dev-3" });
  await dispatch(rec.router, c, "docs.unpublish", { grantId: "someone-elses" });
  assert.deepEqual(seen, { grantId: "someone-elses", owner: "dev-3" });
  assert.equal(acks(c).length, 1, "the refusal is silent — it still acks {ok}");
  assert.equal(errs(c).length, 0, "no err would leak that the id exists");
});
