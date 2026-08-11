import assert from "node:assert/strict";
import { test } from "node:test";

import { CommandRouter } from "../command_router.js";
import type { OutgoingFrame, WsClient } from "../client.js";
import type { CommandDeps } from "./deps.js";
import { register as registerPorts } from "./ports.js";
import type { PortKillOutcome, PortKillTarget } from "../../protocol.js";

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

interface Recorder {
  router: CommandRouter;
  recounts: number;
  snapshotSends: WsClient[];
  /** SPEC-43: every target `ports.kill` forwarded to the service. */
  killTargets: PortKillTarget[];
  /** SPEC-43: immediate re-scan requests (only a releasing outcome earns one). */
  rescans: number;
  /** SPEC-44: watch-list writes the handler asked for. */
  watchWrites: { target: { worktreePath: string; port: number }; on: boolean }[];
  /** SPEC-44 P4b: forward asks + stops the handler forwarded. */
  forwardAsks: { worktreePath: string; port: number; browser?: boolean }[];
  stops: string[];
}

function setup(outcome: PortKillOutcome = "released"): Recorder {
  const rec: Recorder = {
    router: new CommandRouter(),
    recounts: 0,
    snapshotSends: [],
    killTargets: [],
    rescans: 0,
    watchWrites: [],
    forwardAsks: [],
    stops: [],
  };
  // `satisfies` on the ports slice: the object still needs the blanket cast for
  // the members this harness does not stub, but every member it DOES stub is now
  // checked against `CommandDeps`, so a signature change fails here instead of
  // silently passing a wrong shape through `as unknown`.
  const portsDeps = {
    onPortsWatchersChanged: () => {
      rec.recounts++;
    },
    sendPortsSnapshot: (client: WsClient) => {
      rec.snapshotSends.push(client);
    },
    killPort: async (target: PortKillTarget) => {
      rec.killTargets.push(target);
      return { outcome, address: target.address, port: target.port };
    },
    rescanPorts: () => {
      rec.rescans++;
    },
    forwardPort: async (target: { worktreePath: string; port: number; browser?: boolean }) => {
      rec.forwardAsks.push(target);
      return target.port === 5173
        ? {
            grant: {
              grantId: "g-1",
              port: target.port,
              createdAt: 1_000,
              expiresAt: 1_000 + 30 * 60_000,
              path: "/forward/g-1/",
              browser: target.browser === true,
            },
          }
        : { refusal: "database and shell ports are never forwarded" };
    },
    stopForward: (grantId: string) => {
      rec.stops.push(grantId);
    },
    setWatchedPort: (target: { worktreePath: string; port: number }, on: boolean) => {
      rec.watchWrites.push({ target, on });
    },
    killOrphans: async () => ({
      results: [
        { outcome, address: "127.0.0.1", port: 5180 },
        { outcome: "not_found" as const, address: "127.0.0.1", port: 5181 },
      ],
    }),
  } satisfies Pick<
    CommandDeps,
    | "onPortsWatchersChanged"
    | "sendPortsSnapshot"
    | "killPort"
    | "rescanPorts"
    | "forwardPort"
    | "stopForward"
    | "setWatchedPort"
    | "killOrphans"
  >;
  registerPorts(rec.router, portsDeps as unknown as CommandDeps);
  return rec;
}

const dispatch = (r: CommandRouter, c: WsClient, env: Record<string, unknown>) =>
  r.dispatch(c, { v: 1, t: "cmd", id: "1", kind: "ports.watch", ...env } as never);

test("{on:true} acks, sets the flag, recounts, and sends one snapshot", async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, { on: true });
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack").length, 1);
  assert.equal(c.watchingPorts, true);
  assert.equal(rec.recounts, 1);
  assert.deepEqual(rec.snapshotSends, [c]);
});

test("a repeated {on:true} neither re-sends the snapshot nor re-scans (still recounts)", async () => {
  const rec = setup();
  const c = fakeClient({ watchingPorts: true });
  await dispatch(rec.router, c, { on: true });
  assert.equal(rec.snapshotSends.length, 0, "no snapshot re-send on a no-op repeat");
});

test("{on:false} clears the flag and recounts (disarms), sends no snapshot", async () => {
  const rec = setup();
  const c = fakeClient({ watchingPorts: true });
  await dispatch(rec.router, c, { on: false });
  assert.equal(c.watchingPorts, false);
  assert.equal(rec.recounts, 1);
  assert.equal(rec.snapshotSends.length, 0);
});

test('a malformed payload (on:"yes") is a no-op, not a crash', async () => {
  const rec = setup();
  const c = fakeClient();
  await dispatch(rec.router, c, { on: "yes" });
  assert.equal(c.watchingPorts, false, "a non-boolean `on` leaves the flag untouched");
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "err").length, 0);
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack").length, 1);
  assert.equal(rec.snapshotSends.length, 0);
});

test('a malformed payload does NOT disarm a client that is ALREADY watching (T8 no-op)', async () => {
  const rec = setup();
  const c = fakeClient({ watchingPorts: true });
  await dispatch(rec.router, c, { on: "yes" });
  // The flag and the watcher recount must be untouched: a malformed payload must
  // never turn a watching client OFF (which would silently disarm the scanner).
  assert.equal(c.watchingPorts, true, "still watching");
  assert.equal(rec.recounts, 0, "no recompute of the watcher count");
  assert.equal(rec.snapshotSends.length, 0);
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack").length, 1);
});

// ── SPEC-43 P3a: ports.kill ────────────────────────────────────────────────

const killDispatch = (
  r: CommandRouter,
  c: WsClient,
  env: Record<string, unknown>,
) => r.dispatch(c, { v: 1, t: "cmd", id: "k1", kind: "ports.kill", ...env } as never);

const VALID_TUPLE = { address: "127.0.0.1", port: 5173, pid: 48211, startedAt: 1_700_000 };

test("a valid tuple is forwarded verbatim and acked with the result", async () => {
  const rec = setup("released");
  const c = fakeClient();
  await killDispatch(rec.router, c, VALID_TUPLE);
  assert.deepEqual(rec.killTargets, [VALID_TUPLE]);
  const ack = (c as ReturnType<typeof fakeClient>).sent.find((f) => f.t === "ack");
  assert.ok(ack);
  assert.equal((ack as { outcome?: string }).outcome, "released");
  assert.equal((ack as { port?: number }).port, 5173);
});

test("a releasing outcome asks for ONE immediate re-scan", async () => {
  for (const outcome of ["released", "force-killed"] as PortKillOutcome[]) {
    const rec = setup(outcome);
    await killDispatch(rec.router, fakeClient(), VALID_TUPLE);
    assert.equal(rec.rescans, 1, `${outcome} must refresh every watching list`);
  }
});

test("a refusal ACKS its outcome and asks for NO re-scan", async () => {
  // Refusals are outcomes, not errors: each has its own sentence in the UI, and
  // converting one into an `err` frame is the mutation this bites.
  for (const outcome of [
    "not_found",
    "identity_mismatch",
    "not_owned",
    "refused_protected",
    "refused_self",
    "refused_session",
    "scan_unavailable",
    "survived",
  ] as PortKillOutcome[]) {
    const rec = setup(outcome);
    const c = fakeClient();
    await killDispatch(rec.router, c, VALID_TUPLE);
    const sent = (c as ReturnType<typeof fakeClient>).sent;
    assert.equal(sent.filter((f) => f.t === "err").length, 0, `${outcome} must not be an err`);
    const ack = sent.find((f) => f.t === "ack") as { outcome?: string } | undefined;
    assert.equal(ack?.outcome, outcome);
    assert.equal(rec.rescans, 0, `${outcome} released nothing — no broadcast`);
  }
});

test("a malformed tuple is bad_request and NEVER reaches killPort", async () => {
  const broken: Record<string, unknown>[] = [
    {},
    { ...VALID_TUPLE, pid: undefined },
    { ...VALID_TUPLE, pid: "48211" },
    { ...VALID_TUPLE, pid: Number.NaN },
    { ...VALID_TUPLE, startedAt: undefined },
    { ...VALID_TUPLE, port: 0 },
    { ...VALID_TUPLE, port: 70_000 },
    { ...VALID_TUPLE, address: "" },
    { ...VALID_TUPLE, address: 127 },
  ];
  for (const env of broken) {
    const rec = setup();
    const c = fakeClient();
    await killDispatch(rec.router, c, env);
    const sent = (c as ReturnType<typeof fakeClient>).sent;
    assert.equal(
      sent.filter((f) => f.t === "err").length,
      1,
      `${JSON.stringify(env)} should be rejected`,
    );
    assert.equal(sent.filter((f) => f.t === "ack").length, 0);
    assert.deepEqual(rec.killTargets, [], "no signal path may run on a malformed payload");
  }
});

test("an unparsable startedAt is refused rather than defaulted (D1)", async () => {
  // Coercing a missing start time to 0 would make every listener whose `etime`
  // was unparsable look verifiable, defeating the identity check outright.
  const rec = setup();
  const c = fakeClient();
  await killDispatch(rec.router, c, { ...VALID_TUPLE, startedAt: "yesterday" });
  assert.deepEqual(rec.killTargets, []);
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "err").length, 1);
});

// ── SPEC-43 P3b: ports.killOrphans ─────────────────────────────────────────

test("ports.killOrphans acks a result PER endpoint (never one verdict)", async () => {
  const rec = setup("released");
  const c = fakeClient();
  await rec.router.dispatch(c, {
    v: 1,
    t: "cmd",
    id: "o1",
    kind: "ports.killOrphans",
  } as never);
  const ack = (c as ReturnType<typeof fakeClient>).sent.find((f) => f.t === "ack") as
    | { results?: { port: number; outcome: string }[] }
    | undefined;
  assert.deepEqual(ack?.results?.map((r) => [r.port, r.outcome]), [
    [5180, "released"],
    [5181, "not_found"],
  ]);
  assert.equal(rec.rescans, 1, "one of them released — refresh the lists once");
});

test("ports.killOrphans that released NOTHING asks for no re-scan", async () => {
  const rec = setup("not_found");
  await rec.router.dispatch(fakeClient(), {
    v: 1,
    t: "cmd",
    id: "o2",
    kind: "ports.killOrphans",
  } as never);
  assert.equal(rec.rescans, 0);
});

// ── SPEC-44 P4a: ports.watchPort ───────────────────────────────────────────

const watchPortDispatch = (
  r: CommandRouter,
  c: WsClient,
  env: Record<string, unknown>,
) => r.dispatch(c, { v: 1, t: "cmd", id: "wp1", kind: "ports.watchPort", ...env } as never);

test("ports.watchPort writes the toggle and acks", async () => {
  const rec = setup();
  const c = fakeClient();
  await watchPortDispatch(rec.router, c, { worktreePath: "/wt/a", port: 5173, on: true });
  assert.deepEqual(rec.watchWrites, [{ target: { worktreePath: "/wt/a", port: 5173 }, on: true }]);
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack").length, 1);

  await watchPortDispatch(rec.router, c, { worktreePath: "/wt/a", port: 5173, on: false });
  assert.equal(rec.watchWrites.at(-1)?.on, false);
});

test("a malformed ports.watchPort writes NOTHING and errs", async () => {
  const broken: Record<string, unknown>[] = [
    {},
    { worktreePath: "/wt/a", port: 5173 },
    { worktreePath: "", port: 5173, on: true },
    { worktreePath: "/wt/a", port: "5173", on: true },
    { worktreePath: "/wt/a", port: 5173, on: "yes" },
    { port: 5173, on: true },
  ];
  for (const env of broken) {
    const rec = setup();
    const c = fakeClient();
    await watchPortDispatch(rec.router, c, env);
    assert.deepEqual(rec.watchWrites, [], `${JSON.stringify(env)} must not write`);
    assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "err").length, 1);
  }
});

// ── SPEC-44 P4b: ports.forward / ports.forward.stop ────────────────────────

const fwd = (r: CommandRouter, c: WsClient, env: Record<string, unknown>, kind = "ports.forward") =>
  r.dispatch(c, { v: 1, t: "cmd", id: "f1", kind, ...env } as never);

test("ports.forward acks a grant for an eligible port", async () => {
  const rec = setup();
  const c = fakeClient();
  await fwd(rec.router, c, { worktreePath: "/wt/a", port: 5173 });
  assert.deepEqual(rec.forwardAsks, [
    { worktreePath: "/wt/a", port: 5173, browser: false },
  ]);
  const ack = (c as ReturnType<typeof fakeClient>).sent.find((f) => f.t === "ack") as
    | { grant?: { grantId: string; expiresAt: number } }
    | undefined;
  assert.equal(ack?.grant?.grantId, "g-1");
  assert.ok((ack?.grant?.expiresAt ?? 0) > 1_000, "the grant states when it dies");
});

test("a refused forward errs with the REASON and mints nothing", async () => {
  const rec = setup();
  const c = fakeClient();
  await fwd(rec.router, c, { worktreePath: "/wt/a", port: 5432 });
  const err = (c as ReturnType<typeof fakeClient>).sent.find((f) => f.t === "err") as
    | { message?: string }
    | undefined;
  assert.match(err?.message ?? "", /database and shell ports/);
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack").length, 0);
});

test("a malformed ports.forward never reaches the mint", async () => {
  for (const env of [{}, { port: 5173 }, { worktreePath: "/wt/a" }, { worktreePath: "", port: 5173 }, { worktreePath: "/wt/a", port: "5173" }]) {
    const rec = setup();
    const c = fakeClient();
    await fwd(rec.router, c, env);
    assert.deepEqual(rec.forwardAsks, [], JSON.stringify(env));
    assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "err").length, 1);
  }
});

test("ports.forward.stop revokes and always acks", async () => {
  const rec = setup();
  const c = fakeClient();
  await fwd(rec.router, c, { grantId: "g-1" }, "ports.forward.stop");
  assert.deepEqual(rec.stops, ["g-1"]);
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "ack").length, 1);
});

test("ports.forward.stop without a grantId is bad_request", async () => {
  const rec = setup();
  const c = fakeClient();
  await fwd(rec.router, c, {}, "ports.forward.stop");
  assert.deepEqual(rec.stops, []);
  assert.equal((c as ReturnType<typeof fakeClient>).sent.filter((f) => f.t === "err").length, 1);
});

test("browser:true is passed through, and anything else is the STRICT mode", async () => {
  // The capability mode has to be asked for with a literal `true`: a truthy
  // string arriving from a stale client must not silently weaken the grant.
  const cases: [unknown, boolean][] = [
    [true, true],
    [false, false],
    ["true", false],
    [1, false],
    [undefined, false],
  ];
  for (const [sent, expected] of cases) {
    const rec = setup();
    const c = fakeClient();
    await fwd(rec.router, c, { worktreePath: "/wt/a", port: 5173, browser: sent });
    assert.equal(rec.forwardAsks[0]?.browser, expected, `browser:${JSON.stringify(sent)}`);
    const ack = (c as ReturnType<typeof fakeClient>).sent.find((f) => f.t === "ack") as
      | { grant?: { browser: boolean; path: string } }
      | undefined;
    assert.equal(ack?.grant?.browser, expected);
    assert.equal(ack?.grant?.path, "/forward/g-1/", "the client is told what to open");
  }
});
