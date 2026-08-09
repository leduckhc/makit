/**
 * SPEC-38 routing tests for the four PR/worktree commands added by the next-step
 * bar: `worktree.wrapUp`, `worktree.discard`, `pr.markReady`, `pr.updateBranch`
 * and `pr.squashMerge`.
 *
 * Unit tests on the manager prove the *operations*; these prove the **wire**:
 * that each kind is registered, validates its params, acks the payload the app
 * decodes, rebroadcasts the repos snapshot, and turns a thrown error into an
 * `err` frame rather than a silent success. None of that is covered by the
 * manager's own tests, and a missing `register()` call would otherwise only show
 * up at runtime.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { CommandRouter } from "../../src/ws/command_router.js";
import { register } from "../../src/ws/commands/worktree.js";
import type { CommandDeps } from "../../src/ws/commands/deps.js";
import { portsDepsStub } from "./ports_deps_stub.js";
import type { WsClient, OutgoingFrame } from "../../src/ws/client.js";
import type { Envelope } from "../../src/protocol.js";

interface FakeClient extends WsClient {
  sent: OutgoingFrame[];
}

function fakeClient(): FakeClient {
  const sent: OutgoingFrame[] = [];
  return {
    sent,
    authed: true,
    subscribed: new Set<string>(),
    watchingMetrics: false,
    // SPEC-41: the ports watch flag is required on WsClient (a router built
    // without it would ACK `ports.watch` and then never scan), so every fake
    // client declares it. This domain does not exercise ports.
    watchingPorts: false,
    isLocal: true,
    send: (frame) => sent.push(frame),
    close: () => {},
  };
}

const cmd = (kind: string, fields: Record<string, unknown> = {}): Envelope =>
  ({ v: 1, t: "cmd", id: "c1", kind, ...fields }) as Envelope;

function routerWith(manager: Partial<CommandDeps["manager"]>) {
  const router = new CommandRouter();
  let broadcasts = 0;
  const deps = {
    manager: manager as CommandDeps["manager"],
    gateway: {} as CommandDeps["gateway"],
    budgetWatch: {} as CommandDeps["budgetWatch"],
    broadcastSnapshots: () => {},
    broadcastReposSnapshot: async () => {
      broadcasts += 1;
    },
    broadcastBudget: () => {},
    onMetricsWatchersChanged: () => {},
    sendMetricsHistory: () => {},
    // SPEC-41: required members, inert here — the PR domain sends no ports frames.
    onPortsWatchersChanged: () => {},
    sendPortsSnapshot: () => {},
    ...portsDepsStub,
    askDevice: async () => ({}) as Envelope,
  } satisfies CommandDeps;
  register(router, deps);
  return { router, client: fakeClient(), broadcasts: () => broadcasts };
}

const ackOf = (c: FakeClient) => c.sent.find((f) => f.t === "ack") as any;
const errOf = (c: FakeClient) => c.sent.find((f) => f.t === "err") as any;

const OK = { projectId: "p1", worktreePath: "/wt/x" };

test("worktree.wrapUp acks the whole report the app decodes", async () => {
  // Every field matters: `WrapUpReport.summary` builds its line from
  // branchDeleted + baseBranch + baseUpdated, and the "Why?" action needs
  // baseReason. Dropping any of them degrades the message silently.
  const { router, client, broadcasts } = routerWith({
    wrapUpWorktree: async () => ({
      branchDeleted: "feat/x",
      baseBranch: "main",
      baseUpdated: false,
      baseReason: "main has local commits that are not on origin/main",
    }),
  });
  await router.dispatch(client, cmd("worktree.wrapUp", { ...OK, baseBranch: "main" }));
  const ack = ackOf(client);
  assert.ok(ack, "expected an ack");
  assert.equal(ack.projectId, "p1");
  assert.equal(ack.worktreePath, "/wt/x");
  assert.equal(ack.branchDeleted, "feat/x");
  assert.equal(ack.baseBranch, "main");
  assert.equal(ack.baseUpdated, false);
  assert.match(String(ack.baseReason), /local commits/);
  assert.equal(broadcasts(), 1, "the row must refresh");
});

test("worktree.wrapUp forwards the PR's own base branch", async () => {
  // The base is not always `main`; passing it is what makes a release-branch PR
  // fast-forward the right ref.
  const seen: unknown[] = [];
  const { router, client } = routerWith({
    wrapUpWorktree: async (_p: string, _w: string, base?: string) => {
      seen.push(base);
      return { baseUpdated: true };
    },
  });
  await router.dispatch(
    client,
    cmd("worktree.wrapUp", { ...OK, baseBranch: "release/2.0" }),
  );
  assert.deepEqual(seen, ["release/2.0"]);
});

test("worktree.discard acks the branch it deleted", async () => {
  const { router, client, broadcasts } = routerWith({
    discardWorktree: async () => ({ branchDeleted: "feat/x", baseUpdated: false }),
  });
  await router.dispatch(client, cmd("worktree.discard", OK));
  assert.equal(ackOf(client).branchDeleted, "feat/x");
  assert.equal(broadcasts(), 1);
});

for (const [kind, method] of [
  ["pr.markReady", "markPrReady"],
  ["pr.updateBranch", "updatePrBranch"],
  ["pr.squashMerge", "squashMergePr"],
] as const) {
  test(`${kind} calls ${method} and rebroadcasts`, async () => {
    const calls: Array<[string, string]> = [];
    const { router, client, broadcasts } = routerWith({
      [method]: async (p: string, w: string) => {
        calls.push([p, w]);
      },
    } as Partial<CommandDeps["manager"]>);
    await router.dispatch(client, cmd(kind, OK));
    assert.deepEqual(calls, [["p1", "/wt/x"]]);
    assert.ok(ackOf(client), "expected an ack");
    // The mutation changed state on GitHub, so the snapshot must refresh —
    // otherwise the row keeps reporting what the mutation just changed.
    assert.equal(broadcasts(), 1);
  });

  test(`${kind} reports gh's error instead of acking`, async () => {
    const { router, client, broadcasts } = routerWith({
      [method]: async () => {
        throw new Error("gh said no");
      },
    } as Partial<CommandDeps["manager"]>);
    await router.dispatch(client, cmd(kind, OK));
    assert.equal(ackOf(client), undefined, "must not claim success");
    assert.match(String(errOf(client).message), /gh said no/);
    assert.equal(broadcasts(), 0, "nothing changed, so nothing to rebroadcast");
  });
}

for (const kind of [
  "worktree.wrapUp",
  "worktree.discard",
  "pr.markReady",
  "pr.updateBranch",
  "pr.squashMerge",
]) {
  test(`${kind} rejects a missing worktreePath`, async () => {
    // These all destroy or publish something; acting on a blank path would be
    // acting on the repo root.
    const { router, client } = routerWith({});
    await router.dispatch(client, cmd(kind, { projectId: "p1" }));
    assert.equal(ackOf(client), undefined);
    assert.match(String(errOf(client).message), /worktreePath/);
  });

  test(`${kind} rejects a missing projectId`, async () => {
    const { router, client } = routerWith({});
    await router.dispatch(client, cmd(kind, { worktreePath: "/wt/x" }));
    assert.equal(ackOf(client), undefined);
    assert.match(String(errOf(client).message), /projectId/);
  });
}
