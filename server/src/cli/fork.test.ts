/**
 * SPEC-46 U4 — `makit fork <id>`: the adapter-native fork the plan completes
 * from SPEC-29's PENDING item.
 *
 * A fork is NOT a handoff (D6): no manifest, no first message — the source is
 * named on the argv and the server branches the identical conversation. What
 * this CLI is responsible for is the D15-inverse tree inheritance (the child
 * runs in the source's worktree/branch unless `--worktree`) and turning a
 * server refusal into a sentence rather than a stack trace in an agent's shell.
 *
 * The server-side decisions (capability gate, rollout precondition, lineage,
 * the depth bound, the promotion trap) are proven where they live —
 * `ws/commands/session.test.ts`, `manager.test.ts`, `adapters/codex.test.ts`.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { parseForkArgs, runFork } from "./fork.js";
import { cliCredentialPath } from "./client.js";
import { createControlServer, type ControlBackend } from "../daemon/control-server.js";
import { controlSocketPath } from "../daemon/paths.js";
import { startStubWss } from "../../test/support/stub_wss.js";

const SOURCE = {
  id: "src-sid",
  projectId: "p1",
  agent: "codex",
  title: "make the migration idempotent",
  status: "running",
  lastActivityAt: 1,
  branch: "fix-the-migration",
  worktreePath: "/tmp/repo-wt/fix-the-migration",
};

function stubBackend(): ControlBackend {
  const unused = () => {
    throw new Error("not used by fork");
  };
  return {
    status: unused,
    pairMint: unused,
    pairCurrent: unused,
    devicesList: unused,
    devicesRevoke: unused,
    sessionsList: unused,
    serverStop: unused,
    logsTail: unused,
    cliGrant: () => ({ deviceId: "cli-1", label: "cli@h", bearer: "CACHED", created: true }),
  } as unknown as ControlBackend;
}

interface Run {
  out: string;
  err: string;
  code: number;
  cmds: Record<string, unknown>[];
}

async function run(
  argv: string[],
  opts: { sessions?: unknown[]; forkErr?: string } = {},
): Promise<Run> {
  const cmds: Record<string, unknown>[] = [];
  const stub = await startStubWss({
    acceptBearer: "CACHED",
    sessions: opts.sessions ?? [SOURCE],
    projects: [{ id: "p1", name: "makit", path: "/tmp/repo", pinned: false, lastActivityAt: 0 }],
    onCmd: (m) => {
      cmds.push(m);
      if (m.kind === "session.fork") {
        return opts.forkErr ? { __err: opts.forkErr } : { sessionId: "child-sid" };
      }
      if (m.kind === "worktree.create") return { path: "/tmp/repo-wt/fresh", branch: "fresh" };
      return {};
    },
  });

  const home = mkdtempSync(join(tmpdir(), "makit-fork-home-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;
  mkdirSync(home, { recursive: true });
  writeFileSync(cliCredentialPath(), JSON.stringify({ deviceId: "cli-1", label: "cli@h", bearer: "CACHED" }));
  const control = await createControlServer({ socketPath: controlSocketPath(), backend: stubBackend() });

  let out = "";
  let err = "";
  let code = 0;
  const origLog = console.log;
  const origErr = console.error;
  const origExit = process.exit;
  console.log = (...a: unknown[]) => {
    out += a.join(" ") + "\n";
  };
  console.error = (...a: unknown[]) => {
    err += a.join(" ") + "\n";
  };
  process.exit = ((c?: number) => {
    code = c ?? 0;
    throw new Error(`__exit__:${c}`);
  }) as typeof process.exit;
  try {
    await runFork([...argv, "--port", String(stub.port)]);
  } catch (e) {
    if (!/^__exit__:/.test((e as Error).message)) throw e;
  } finally {
    console.log = origLog;
    console.error = origErr;
    process.exit = origExit;
    await control.close();
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    await stub.close();
  }
  return { out, err, code, cmds };
}

const sent = (cmds: Record<string, unknown>[], kind: string) => cmds.find((c) => c.kind === kind);

// ---------------------------------------------------------------------------
// argv parsing
// ---------------------------------------------------------------------------

test("parseForkArgs: positional id, --agent, --worktree", () => {
  const a = parseForkArgs(["src-sid", "--agent", "codex", "--worktree"]);
  assert.equal(a.sessionId, "src-sid");
  assert.equal(a.agent, "codex");
  assert.equal(a.freshWorktree, true);
});

test("fork with no id is a usage error, and nothing is created", async () => {
  const r = await run([]);
  assert.equal(r.code, 2);
  assert.match(r.err, /usage: makit fork/);
  assert.equal(r.cmds.length, 0);
});

// ---------------------------------------------------------------------------
// D15 inverse — inherit the source's tree unless asked otherwise
// ---------------------------------------------------------------------------

test("the child inherits the source's worktree and branch, creating no tree", async () => {
  const r = await run(["src-sid"]);
  assert.equal(r.code, 0, r.err);
  assert.equal(sent(r.cmds, "worktree.create"), undefined);
  const fork = sent(r.cmds, "session.fork")!;
  assert.equal(fork.sessionId, "src-sid");
  assert.equal(fork.worktreePath, SOURCE.worktreePath);
  assert.equal(fork.branch, SOURCE.branch);
});

test("--worktree opts into a fresh tree", async () => {
  const r = await run(["src-sid", "--worktree"]);
  assert.ok(sent(r.cmds, "worktree.create"), "a fresh tree was asked for");
  const fork = sent(r.cmds, "session.fork")!;
  assert.equal(fork.worktreePath, "/tmp/repo-wt/fresh");
  assert.equal(fork.branch, "fresh");
});

test("--agent picks the harness for the child", async () => {
  const r = await run(["src-sid", "--agent", "codex"]);
  assert.equal(sent(r.cmds, "session.fork")!.agent, "codex");
});

test("--json prints just the child session id", async () => {
  const r = await run(["src-sid", "--json"]);
  assert.equal(r.code, 0, r.err);
  assert.deepEqual(JSON.parse(r.out.trim()), { sessionId: "child-sid" });
});

test("the default output names the child session and its branch", async () => {
  const r = await run(["src-sid"]);
  assert.match(r.out, /forked/);
  assert.match(r.out, /child-sid/);
  assert.match(r.out, /fix-the-migration/);
});

// ---------------------------------------------------------------------------
// a server refusal is a clean sentence, not a stack trace (D6)
// ---------------------------------------------------------------------------

test("a refused fork is a clean message and exit 1, not a wall of node frames", async () => {
  const r = await run(["src-sid"], {
    forkErr: "pi cannot fork: pi-acp advertises no `session/fork` — use `makit handoff` instead",
  });
  assert.equal(r.code, 1);
  assert.match(r.err, /use `makit handoff` instead/);
  assert.doesNotMatch(r.err, /at Object|node:internal/);
});

// ---------------------------------------------------------------------------
// An unresolvable source is refused, never forked blind
//
// The child's tree is resolved from the snapshot and sent to the server, which
// takes `worktreePath` at face value rather than re-deriving it from the source.
// So a source that is missing from the snapshot but resolvable server-side —
// an closed session is exactly that — would be forked with NO worktree,
// silently contradicting the inherit-the-source's-tree rule. `--worktree`
// already refuses this case; the default path must too.
// ---------------------------------------------------------------------------

test("a source that is not in the snapshot is refused, not forked with no worktree", async () => {
  const r = await run(["ghost-sid"], { sessions: [SOURCE] });
  assert.equal(r.code, 2);
  assert.match(r.err, /ghost-sid/);
  assert.equal(sent(r.cmds, "session.fork"), undefined, "nothing may be forked from a source we cannot read");
});

test("a source with no worktree of its own still forks (a --here session is legitimate)", async () => {
  const here = { ...SOURCE, worktreePath: undefined, branch: undefined };
  const r = await run(["src-sid"], { sessions: [here] });
  assert.equal(r.code, 0, r.err);
  const fork = sent(r.cmds, "session.fork")!;
  assert.equal(fork.worktreePath, undefined);
});
