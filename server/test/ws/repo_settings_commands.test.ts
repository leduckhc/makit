/**
 * `repo.settings.set` — the only per-repo write, and the loopback gate on it.
 *
 * The gate is the point of this file. A paired phone that could set `worktreeRoot`
 * would be directing host filesystem operations at a path of its choosing: the
 * daemon creates directories under that root and, via prune, removes them. So the
 * refusal is asserted here, on the server, against `WsClient.isLocal` — the same
 * flag that already refuses a non-loopback client's reported pid (SPEC-37 D6).
 */
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
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
    watchingDocs: false,
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
const createdRoots: string[] = [];

function goodRoot(): string {
  // Inside the real home because the handler calls `validateWorktreeRoot` with no
  // `home` argument, so the containment rule is checked against the real one. Unique
  // per call and removed in `after`, instead of leaving a directory behind in the
  // developer's home and on CI agents.
  const root = mkdtempSync(join(homedir(), ".makit-test-cmd-trees-"));
  createdRoots.push(root);
  return root;
}

after(() => {
  for (const root of createdRoots) rmSync(root, { recursive: true, force: true });
});

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

// ---------------------------------------------------------------------------
// `repo.path.set` — re-pointing a project that moved on disk (SPEC-48 D4').
//
// A separate command from `repo.settings.set` because it is not a setting: it
// mutates the project record itself, has to re-validate that the target is a git
// repo, and re-runs forge detection. Folding it into the settings patch would put
// an async filesystem-and-subprocess check inside a loop that validates plain
// values, and one bad field would then abort a half-done move.
//
// The same loopback gate applies, for a sharper reason than the worktree root: this
// decides the directory every session's git commands run in.
// ---------------------------------------------------------------------------

const pathCmd = (fields: Partial<Envelope>): Envelope =>
  ({ v: 1, t: "cmd", id: "c1", kind: "repo.path.set", ...fields }) as Envelope;

/** As {@link harness}, but recording `repointProject` and its answer. */
function pathHarness(result: { ok: true; path: string } | { ok: false; error: string }) {
  const calls: Array<[string, string]> = [];
  let broadcasts = 0;
  const router = new CommandRouter();
  const deps = {
    manager: {
      repointProject: async (id: string, path: string) => {
        calls.push([id, path]);
        return result;
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
  return { router, calls, broadcasts: () => broadcasts };
}

test("a non-loopback client cannot re-point a repository", async () => {
  // Sharper than the worktree-root gate: this names the directory every session's
  // git commands run in, so a paired phone could redirect all of them.
  const { router, calls } = pathHarness({ ok: true, path: "/x" });
  const c = fakeClient(false);
  await router.dispatch(c, pathCmd({ projectId: "p1", path: "/tmp/anything" }));
  assert.equal(calls.length, 0, "nothing was attempted");
  assert.match(errOf(c)?.message ?? "", /machine running makit/);
});

test("a loopback client re-points and the snapshot is re-broadcast", async () => {
  const { router, calls, broadcasts } = pathHarness({ ok: true, path: "/real/path" });
  const c = fakeClient(true);
  await router.dispatch(c, pathCmd({ projectId: "p1", path: "/real/path" }));
  assert.deepEqual(calls, [["p1", "/real/path"]]);
  assert.ok(ackOf(c), "acked");
  assert.equal(broadcasts(), 1, "every client re-renders from one source");
});

test("a refusal is an explicit error carrying the reason verbatim", async () => {
  // The reasons are actionable — "not a git repository", "already open as X" — and a
  // generic failure would throw away the only part the user can act on.
  const { router, broadcasts } = pathHarness({
    ok: false,
    error: "/tmp/plain is not a git repository.",
  });
  const c = fakeClient(true);
  await router.dispatch(c, pathCmd({ projectId: "p1", path: "/tmp/plain" }));
  assert.equal(errOf(c)?.message, "/tmp/plain is not a git repository.");
  assert.equal(ackOf(c), undefined, "not acked");
  assert.equal(broadcasts(), 0, "and nothing is re-broadcast");
});

test("a missing projectId or path is a bad request, not a crash", async () => {
  const { router, calls } = pathHarness({ ok: true, path: "/x" });
  const noId = fakeClient(true);
  await router.dispatch(noId, pathCmd({ path: "/tmp/x" }));
  assert.ok(errOf(noId));
  const noPath = fakeClient(true);
  await router.dispatch(noPath, pathCmd({ projectId: "p1" }));
  assert.ok(errOf(noPath));
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// Review findings: the key-name rule was skipped for a `null` value.
// ---------------------------------------------------------------------------

test("an unknown key is refused even when its value is null", async () => {
  // The clear-a-setting branch ran BEFORE the switch, so the unknown-key rule never
  // saw a null value: `{wroktreeRoot: null}` was acked and the typo was written into
  // the patch. A settings write that silently stores a misspelling is worse than one
  // that refuses, because the user believes the setting exists.
  const { router, written } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { wroktreeRoot: null } }));
  assert.match(errOf(c)?.message ?? "", /wroktreeRoot/);
  assert.deepEqual(written, [], "and nothing is written");
});

test("__proto__ is refused rather than reaching the patch object", async () => {
  // With the key rule skipped, `applied["__proto__"] = null` invoked the prototype
  // setter instead of creating an own property. Harmless to stored data, but it is
  // input the stated rule refuses, and refusing it here is cheaper than reasoning
  // about every object it is later spread into.
  const { router, written } = harness();
  const c = fakeClient(true);
  // Built with JSON.parse, not a literal: `{__proto__: null}` in source sets the
  // PROTOTYPE and creates no key, so a literal cannot reproduce this at all. Off the
  // wire the value arrives decoded from JSON, which does create an own property --
  // so this is the only faithful reproduction of the real input.
  const hostile = JSON.parse('{"__proto__": null, "worktreeRoot": null}') as Record<string, unknown>;
  await router.dispatch(c, cmd({ projectId: "p1", settings: hostile }));
  assert.ok(errOf(c), "refused");
  assert.deepEqual(written, []);
});

test("a known key with a null value still clears, as the UI relies on", async () => {
  // The guard must not break the reset buttons.
  const { router, written } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { worktreeRoot: null } }));
  assert.ok(ackOf(c));
  assert.deepEqual(written, [["p1", { worktreeRoot: null }]]);
});

test("a logoHue outside the palette is refused, not wrapped", async () => {
  // `RepoMonogram.paletteAt` wraps with `%`, so a stored 6 renders as index 0 — a
  // valid-looking colour the user never chose, and indistinguishable from having
  // chosen 0. Rejecting at the boundary keeps one hue per stored value.
  const { router, written } = harness();
  const c = fakeClient(true);
  await router.dispatch(c, cmd({ projectId: "p1", settings: { logoHue: 6 } }));
  assert.ok(errOf(c));
  assert.deepEqual(written, []);
  const ok = fakeClient(true);
  await router.dispatch(ok, cmd({ projectId: "p1", settings: { logoHue: 5 } }));
  assert.ok(ackOf(ok), "the last valid index is still accepted");
});
