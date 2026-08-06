import assert from "node:assert/strict";
import { test } from "node:test";

import { attribute, MAX_COMMAND_CHARS, tailnetAddressFromBindHost, type AttributeInput } from "./attribute.js";
import type { ProcInfo } from "./proc.js";
import type { Listener } from "./scan.js";
import type { PortHealthDTO } from "../protocol.js";

function proc(pid: number, ppid: number, command = `p${pid}`, startedAt?: number): ProcInfo {
  return { pid, ppid, command, startedAt };
}

/** Identity realpath so tests control aliasing explicitly where they need it. */
const identityResolver = (p: string): string => p;

function run(overrides: Partial<AttributeInput>): ReturnType<typeof attribute> {
  const base: AttributeInput = {
    listeners: [],
    procs: new Map(),
    cwds: new Map(),
    worktreePaths: [],
    sessionRoots: new Map(),
    health: () => undefined,
    tailnetAddress: null,
    resolveReal: identityResolver,
  };
  return attribute({ ...base, ...overrides });
}

const listener = (over: Partial<Listener> = {}): Listener => ({
  pid: 200,
  uid: 501,
  address: "127.0.0.1",
  port: 5173,
  ...over,
});

test("a listener whose PARENT owns the cwd is attributed (the rev-1 blocker)", () => {
  // node (200, listens, cwd '/') is a child of pnpm (100, cwd the worktree).
  const ports = run({
    listeners: [listener({ pid: 200 })],
    procs: new Map([[100, proc(100, 1)], [200, proc(200, 100)]]),
    cwds: new Map([[200, "/"], [100, "/repo/wt-a"]]),
    worktreePaths: ["/repo/wt-a"],
  });
  assert.equal(ports[0]!.worktreePath, "/repo/wt-a");
});

test("longest-prefix beats an ancestor repo (own nested cwd wins)", () => {
  const ports = run({
    listeners: [listener({ pid: 200 })],
    procs: new Map([[100, proc(100, 1)], [200, proc(200, 100)]]),
    cwds: new Map([[200, "/repo/wt-a/packages/api"], [100, "/repo"]]),
    worktreePaths: ["/repo", "/repo/wt-a"],
  });
  assert.equal(ports[0]!.worktreePath, "/repo/wt-a");
});

test("segment-wise prefix: /a/b-2 does NOT match the worktree /a/b", () => {
  const ports = run({
    listeners: [listener({ pid: 200 })],
    procs: new Map([[200, proc(200, 1)]]),
    cwds: new Map([[200, "/a/b-2/src"]]),
    worktreePaths: ["/a/b"],
  });
  assert.equal(ports[0]!.worktreePath, undefined, "b-2 is not under b");
});

test("realpath aliasing: a /tmp cwd matches a /private/tmp worktree", () => {
  const aliasResolver = (p: string): string => (p.startsWith("/private/") ? p : `/private${p}`);
  const ports = run({
    listeners: [listener({ pid: 200 })],
    procs: new Map([[200, proc(200, 1)]]),
    cwds: new Map([[200, "/tmp/wt"]]),
    worktreePaths: ["/private/tmp/wt"],
    resolveReal: aliasResolver,
  });
  assert.equal(ports[0]!.worktreePath, "/private/tmp/wt");
});

test("sessionId: a pid in descendants(agentPid) is linked, and the index is built once", () => {
  // session root 100 → child 150 → listening grandchild 200.
  const ports = run({
    listeners: [listener({ pid: 200 })],
    procs: new Map([[100, proc(100, 1)], [150, proc(150, 100)], [200, proc(200, 150)]]),
    sessionRoots: new Map([["sess-1", 100]]),
  });
  assert.equal(ports[0]!.sessionId, "sess-1");
});

test("an unowned listener stays unowned (no worktree, no session)", () => {
  const ports = run({
    listeners: [listener({ pid: 200 })],
    procs: new Map([[200, proc(200, 1)]]),
    cwds: new Map([[200, "/somewhere/else"]]),
    worktreePaths: ["/repo/wt-a"],
  });
  assert.equal(ports[0]!.worktreePath, undefined);
  assert.equal(ports[0]!.sessionId, undefined);
});

test("reach: a wildcard bind is 'exposed', never 'tailnet'", () => {
  const [a, b] = run({
    listeners: [listener({ address: "0.0.0.0", port: 3000 }), listener({ address: "*", port: 3001 })],
    tailnetAddress: "100.119.58.97",
  });
  assert.equal(a!.reach, "exposed");
  assert.equal(b!.reach, "exposed");
});

test("reach: an exact tailnet address match is 'tailnet'", () => {
  const ports = run({
    listeners: [listener({ address: "100.119.58.97", port: 7808 })],
    tailnetAddress: "100.119.58.97",
  });
  assert.equal(ports[0]!.reach, "tailnet");
});

test("reach: loopback addresses are 'loopback'", () => {
  const [a, b] = run({
    listeners: [listener({ address: "127.0.0.1", port: 1 }), listener({ address: "::1", port: 2 })],
    tailnetAddress: "100.119.58.97",
  });
  assert.equal(a!.reach, "loopback");
  assert.equal(b!.reach, "loopback");
});

const okHealth: PortHealthDTO = { kind: "ok", status: 200, probedAt: 123 };

/**
 * cwds + worktreePaths that make the default (pid 200) listener worktree-owned,
 * so its health is read (D3: health is attached ONLY for worktree-owned ports).
 */
const ownedByWt = { cwds: new Map([[200, "/wt"]]), worktreePaths: ["/wt"] };

test("D3: a port that BECOMES unowned drops BOTH its health and its openUrl (warm cache)", () => {
  const health = () => okHealth; // warm cache: a verdict exists for this endpoint
  const listeners = [listener({ pid: 200, address: "127.0.0.1", port: 5173 })];
  const procs = new Map([[200, proc(200, 1)]]);
  // First call: pid 200's cwd is under the worktree → owned → probed → openUrl.
  const owned = run({ listeners, procs, cwds: new Map([[200, "/wt"]]), worktreePaths: ["/wt"], health });
  assert.equal(owned[0]!.worktreePath, "/wt");
  assert.ok(owned[0]!.health, "an owned port carries the cached verdict");
  assert.equal(owned[0]!.openUrl, "http://127.0.0.1:5173");
  // Second call: SAME endpoint, cache still warm, but now UNOWNED.
  const unowned = run({ listeners, procs, cwds: new Map([[200, "/elsewhere"]]), worktreePaths: ["/wt"], health });
  assert.equal(unowned[0]!.worktreePath, undefined);
  assert.equal(unowned[0]!.health, undefined, "an unowned port must not attach a stale verdict");
  assert.equal(unowned[0]!.openUrl, undefined, "and therefore no openUrl");
});

test("openUrl: 127.0.0.1 with an HTTP verdict → http://127.0.0.1:<port>", () => {
  const ports = run({ listeners: [listener({ address: "127.0.0.1", port: 5173 })], health: () => okHealth, ...ownedByWt });
  assert.equal(ports[0]!.openUrl, "http://127.0.0.1:5173");
});

test("openUrl: a wildcard IPv4 bind resolves to 127.0.0.1", () => {
  const ports = run({ listeners: [listener({ address: "*", port: 5173 })], health: () => okHealth, ...ownedByWt });
  assert.equal(ports[0]!.openUrl, "http://127.0.0.1:5173");
});

test("openUrl: ::1 / :: are bracketed", () => {
  const [a, b] = run({
    listeners: [listener({ address: "::1", port: 9787 }), listener({ address: "::", port: 9788 })],
    health: () => okHealth,
    ...ownedByWt,
  });
  assert.equal(a!.openUrl, "http://[::1]:9787");
  assert.equal(b!.openUrl, "http://[::1]:9788");
});

test("openUrl: a concrete address is used verbatim", () => {
  const ports = run({
    listeners: [listener({ address: "100.119.58.97", port: 7808 })],
    tailnetAddress: "100.119.58.97",
    health: () => okHealth,
    ...ownedByWt,
  });
  assert.equal(ports[0]!.openUrl, "http://100.119.58.97:7808");
});

test("openUrl: ABSENT when there is no HTTP verdict (unprobed or refused/timeout)", () => {
  const refused: PortHealthDTO = { kind: "refused", probedAt: 1 };
  const [a, b] = run({
    listeners: [listener({ port: 1 }), listener({ port: 2 })],
    health: (_addr, port) => (port === 2 ? refused : undefined),
    ...ownedByWt,
  });
  assert.equal(a!.openUrl, undefined, "unprobed → no openUrl");
  assert.equal(b!.openUrl, undefined, "refused is not an HTTP verdict → no openUrl");
});

test("http-error still yields an openUrl (something answered)", () => {
  const err: PortHealthDTO = { kind: "http-error", status: 404, probedAt: 1 };
  const ports = run({ listeners: [listener()], health: () => err, ...ownedByWt });
  assert.equal(ports[0]!.openUrl, "http://127.0.0.1:5173");
});

test("key is <pid>:<address>:<port>", () => {
  const ports = run({ listeners: [listener({ pid: 42, address: "::1", port: 8080 })] });
  assert.equal(ports[0]!.key, "42:::1:8080");
});

test("command is carried and trimmed to MAX_COMMAND_CHARS", () => {
  const long = "node ".concat("x".repeat(MAX_COMMAND_CHARS + 50));
  const ports = run({
    listeners: [listener({ pid: 200 })],
    procs: new Map([[200, proc(200, 1, long)]]),
  });
  assert.equal(ports[0]!.command.length, MAX_COMMAND_CHARS);
});

test("startedAt is carried through from the proc table when present", () => {
  const ports = run({
    listeners: [listener({ pid: 200 })],
    procs: new Map([[200, proc(200, 1, "node", 111)]]),
  });
  assert.equal(ports[0]!.startedAt, 111);
});

test("ports are sorted by port then pid", () => {
  const ports = run({
    listeners: [
      listener({ pid: 5, port: 8080 }),
      listener({ pid: 2, port: 3000 }),
      listener({ pid: 9, port: 3000 }),
    ],
  });
  assert.deepEqual(
    ports.map((p) => [p.port, p.pid]),
    [[3000, 2], [3000, 9], [8080, 5]],
  );
});

test("ports with the same pid and port are ordered by address (dual-stack, total sort)", () => {
  // A dual-stack process listens on the same port over two addresses with ONE
  // pid; without `address` as a third sort key their order is whatever lsof
  // printed, which makes the dedup projection see a spurious change (finding 17).
  const ports = run({
    listeners: [
      listener({ pid: 7, port: 8080, address: "::1" }),
      listener({ pid: 7, port: 8080, address: "127.0.0.1" }),
    ],
  });
  assert.deepEqual(
    ports.map((p) => p.address),
    ["127.0.0.1", "::1"],
    "ascending by address once port and pid tie",
  );
});

test("tailnetAddressFromBindHost: a 100.x bind host IS the discovered tailnet address (no subprocess)", () => {
  assert.equal(tailnetAddressFromBindHost("100.119.58.97"), "100.119.58.97");
});

test("tailnetAddressFromBindHost: a 100.x address OUTSIDE 100.64.0.0/10 is not a tailnet address", () => {
  // Tailscale's CGNAT range is 100.64.0.0/10 — second octet 64..127 only. A bare
  // `/^100\./` also matches public space (100.0.0.0/10 and 100.128.0.0/9 are NOT
  // CGNAT), which would label a real internet-routable bind as `tailnet` — the
  // reassuring reading of the more alarming fact (spec D2).
  assert.equal(tailnetAddressFromBindHost("100.200.1.1"), null);
  assert.equal(tailnetAddressFromBindHost("100.63.255.255"), null);
  assert.equal(tailnetAddressFromBindHost("100.128.0.1"), null);
  // Both edges of the range are in.
  assert.equal(tailnetAddressFromBindHost("100.64.0.1"), "100.64.0.1");
  assert.equal(tailnetAddressFromBindHost("100.127.255.254"), "100.127.255.254");
});

test("tailnetAddressFromBindHost: loopback / LAN / wildcard binds discover NO tailnet address", () => {
  assert.equal(tailnetAddressFromBindHost("127.0.0.1"), null);
  assert.equal(tailnetAddressFromBindHost("0.0.0.0"), null);
  assert.equal(tailnetAddressFromBindHost("192.168.1.5"), null);
  assert.equal(tailnetAddressFromBindHost("::1"), null);
  assert.equal(tailnetAddressFromBindHost("localhost"), null);
});
