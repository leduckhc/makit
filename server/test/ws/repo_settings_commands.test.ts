/**
 * `repo.settings.set` — the only per-repo write, and the loopback gate on it.
 *
 * The gate is the point of this file. A paired phone that could set `worktreeRoot`
 * would be directing host filesystem operations at a path of its choosing: the
 * daemon creates directories under that root and, via prune, removes them. So the
 * refusal is asserted here, on the server, against `WsClient.isLocal` — the same
 * flag that already refuses a non-loopback client's reported pid (SPEC-37 D6).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, sep } from "node:path";

import { CommandRouter } from "../../src/ws/command_router.js";
import { register } from "../../src/ws/commands/repo_settings.js";
import type { CommandDeps } from "../../src/ws/commands/deps.js";
import { portsDepsStub } from "./ports_deps_stub.js";
import type { WsClient, OutgoingFrame } from "../../src/ws/client.js";
import type { Envelope } from "../../src/protocol.js";

type FakeClient = WsClient & { sent: OutgoingFrame[] };

function fakeClient(isLocal: boolean): FakeClient {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    authed: true,
    subscribed: new Set<string>(),
    watchingMetrics: false,
    watchingPorts: false,
    isLocal,
    send: (frame) => sent.push(frame),
    close: () => {},
  };
}

const cmd = (fields: Partial<Envelope>): Envelope =>
  ({ v: 1, t: "cmd", id: "c1", kind: "repo.settings.set", ...fields }) as Envelope;

function harness() {
  const written: Array<[string, Record<string, unknown>]> = [];
  let broadcasts = 0;
  const router = new CommandRouter();
  const deps = {
    manager: {
      updateProjectSettings: (id: string, patch: Record<string, unknown>) => {
        if (id !== "p1") return false;
        written.push([id, patch]);
        return true;
      },
    },
    gateway: {} as never,
    budgetWatch: {} as never,
    broadcastSnapshots: () => {},
    broadcastReposSnapshot: async () => {},
    broadcastBudget: () => {},
    onMetricsWatchersChanged: () => {},
    sendMetricsHistory: () => {},
    onPortsWatchersChanged: () => {},
    sendPortsSnapshot: () => {},
    onProjectsChanged: () => {
      broadcasts += 1;
    },
    ...portsDepsStub,
    askDevice: async () => ({}) as Envelope,
  } as unknown as CommandDeps;
  register(router, deps);
  return { router, written, broadcasts: () => broadcasts };
}

const ackOf = (c: FakeClient) => c.sent.find((f) => f.t === "ack");
const errOf = (c: FakeClient) => c.sent.find((f) => f.t === "err") as undefined | { message: string };

/** A root that will pass validation: inside the real home, and it exists. */
function goodRoot(): string {
  const root = join(homedir(), ".makit-test-cmd-trees");
  mkdirSync(root, { recursive: true });
  return root;
}

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

test("a non-loopback client is REFUSED, and nothing is written", async () => {
  const { router, written } = harness();
  const c = fakeClient(false);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { worktreeRoot: goodRoot() } }));
  assert.equal(ackOf(c), undefined, "must not ack");
  assert.match(errOf(c)?.message ?? "", /machine running makit/i);
  assert.deepEqual(written, [], "must not write");
});

test("the refusal is an explicit error, never a silent no-op", async () => {
  // A row that appears to save and does not is worse than one that says it cannot.
  const { router } = harness();
  const c = fakeClient(false);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { logoHue: 2 } }));
  assert.equal(c.sent.filter((f) => f.t === "err").length, 1);
});

test("a loopback client is allowed", async () => {
  const { router, written, broadcasts } = harness();
  const c = fakeClient(true);
  const root = goodRoot();
  await router.dispatch(c, cmd({ projectId: "p1", settings: { worktreeRoot: root } }));
  assert.ok(ackOf(c), errOf(c)?.message ?? "no ack");
  assert.equal(written.length, 1);
  assert.equal(broadcasts(), 1, "every client must re-render from one source");
});

// ---------------------------------------------------------------------------
// Validation happens server-side, per field
// ---------------------------------------------------------------------------

test("a relative worktree root is refused", async () => {
  const { router, written } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { worktreeRoot: "work/trees" } }));
  assert.match(errOf(c)?.message ?? "", /absolute/i);
  assert.deepEqual(written, []);
});

test("a worktree root containing '..' is refused on sight", async () => {
  const { router } = harness();
  const c = fakeClient(true);
  const raw = `${homedir()}${sep}work${sep}..${sep}..${sep}etc`;
  await router.dispatch(c, cmd({ projectId: "p1", settings: { worktreeRoot: raw } }));
  assert.match(errOf(c)?.message ?? "", /\.\./);
});

test("a worktree root outside home is refused", async () => {
  const { router } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { worktreeRoot: mkdtempSync(join(tmpdir(), "outside-")) } }));
  assert.match(errOf(c)?.message ?? "", /home directory/i);
});

test("the stored root is the canonicalised one, not the raw string", async () => {
  const { router, written } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { worktreeRoot: goodRoot() } }));
  const stored = written[0][1].worktreeRoot as string;
  assert.ok(stored.length > 0);
  assert.ok(!stored.includes(".."), "no traversal survives the write");
});

test("an unknown provider is refused; the five known ones are accepted", async () => {
  for (const p of ["auto", "none", "forgejo", "gitea", "github"]) {
    const { router, written } = harness();
    const c = fakeClient(true);
    await router.dispatch(c, cmd({ projectId: "p1", settings: { provider: p } }));
    assert.ok(ackOf(c), `${p}: ${errOf(c)?.message}`);
    // `auto` is stored as absence, so the default stays implicit on disk.
    assert.equal(written[0][1].provider, p === "auto" ? null : p);
  }
  const { router, written } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { provider: "gitlab" } }));
  assert.match(errOf(c)?.message ?? "", /gitlab/);
  assert.deepEqual(written, []);
});

test("an invalid branch name is refused before it can reach git", async () => {
  const { router } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { defaultBranch: "bad name" } }));
  assert.match(errOf(c)?.message ?? "", /not a valid branch/i);
});

test("null clears a setting — that is how the UI says 'inherit again'", async () => {
  const { router, written } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { worktreeRoot: null } }));
  assert.ok(ackOf(c));
  assert.equal(written[0][1].worktreeRoot, null);
});

test("an unknown setting key is refused rather than quietly stored", async () => {
  // Otherwise a typo becomes a permanent unused key in projects.json.
  const { router, written } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { wroktreeRoot: "/x" } }));
  assert.match(errOf(c)?.message ?? "", /unknown setting/i);
  assert.deepEqual(written, []);
});

test("one bad field rejects the whole patch — no partial application", async () => {
  const { router, written } = harness();
  const c = fakeClient(true);
  await router.dispatch(
    c,
    cmd({ projectId: "p1", settings: { logoHue: 1, provider: "gitlab" } }),
  );
  assert.ok(errOf(c));
  assert.deepEqual(written, [], "a half-applied patch would be worse than none");
});

test("a missing projectId and a non-object settings are both bad requests", async () => {
  for (const env of [{ settings: {} }, { projectId: "p1", settings: 7 }, { projectId: "p1" }]) {
    const { router } = harness();
    const c = fakeClient(true);
    await router.dispatch(c, cmd(env as Partial<Envelope>));
    assert.ok(errOf(c), JSON.stringify(env));
  }
});

test("an unknown project is reported, not silently ignored", async () => {
  const { router } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "nope", settings: { logoHue: 1 } }));
  assert.match(errOf(c)?.message ?? "", /No project nope/);
});
