/**
 * T19 (SPEC-46) — `makit handoff`: the gesture the whole spec exists for.
 *
 * "This session is out of context. Write a handoff and continue on codex." Today
 * that is a copy-paste ritual across a phone screen; here it is one command the
 * **outgoing agent runs itself**, with no session or project arguments, because
 * the CLI knows who "I" am from `MAKIT_SESSION_ID` / `MAKIT_CLI_TOKEN` in its
 * environment (D3).
 *
 * Two inversions relative to `makit new` are load-bearing:
 *   - **D15 inverse** — a handoff *inherits* the parent's worktree and branch.
 *     Continuity is the point: the manifest's `file:line` references and usually
 *     the uncommitted work live in the parent's tree, so a fresh tree off the
 *     default branch would strand exactly what is being handed over. `--worktree`
 *     opts into a fresh one.
 *   - **D16** — the parent is left alone: not archived, not stopped, not warned
 *     about. Parallel agents in one tree is a decision, not an accident.
 *
 * And D9: the child's `parentId` is **never sent** — the server derives it from
 * the credential, so nothing here can forge ancestry.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { parseHandoffArgs, runHandoff } from "./handoff.js";
import { cliCredentialPath } from "./client.js";
import { createControlServer, type ControlBackend } from "../daemon/control-server.js";
import { controlSocketPath } from "../daemon/paths.js";
import { startStubWss } from "../../test/support/stub_wss.js";

const PARENT = {
  id: "parent-sid",
  projectId: "p1",
  agent: "pi",
  title: "make the migration idempotent",
  status: "running",
  lastActivityAt: 1,
  branch: "fix-the-migration",
  worktreePath: "/tmp/repo-wt/fix-the-migration",
};

function stubBackend(): ControlBackend {
  const unused = () => {
    throw new Error("not used by handoff");
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

/**
 * Run `makit handoff` against a stub server as if from inside session
 * `parent-sid` (an agent's own environment), recording every command frame.
 */
async function run(
  argv: string[],
  opts: { env?: Record<string, string | undefined>; events?: unknown[]; spawnErr?: string } = {},
): Promise<Run> {
  const cmds: Record<string, unknown>[] = [];
  const stub = await startStubWss({
    acceptBearer: "CACHED",
    sessions: [PARENT],
    projects: [{ id: "p1", name: "makit", path: "/tmp/repo", pinned: false, lastActivityAt: 0 }],
    onCmd: (m) => {
      cmds.push(m);
      if (m.kind === "session.spawn") {
        return opts.spawnErr ? { __err: opts.spawnErr } : { sessionId: "child-sid" };
      }
      if (m.kind === "worktree.create") return { path: "/tmp/repo-wt/fresh", branch: "fresh" };
      if (m.kind === "session.transcript") return { events: opts.events ?? [] };
      return {};
    },
  });

  const home = mkdtempSync(join(tmpdir(), "makit-handoff-home-"));
  const prevHome = process.env.MAKIT_HOME;
  const prevEnv: Record<string, string | undefined> = {};
  const env: Record<string, string | undefined> = {
    MAKIT_SESSION_ID: "parent-sid",
    MAKIT_PROJECT_ID: "p1",
    MAKIT_WORKTREE: PARENT.worktreePath,
    ...(opts.env ?? {}),
  };
  for (const [k, v] of Object.entries(env)) {
    prevEnv[k] = process.env[k];
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
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
    await runHandoff([...argv, "--port", String(stub.port)]);
  } catch (e) {
    if (!/^__exit__:/.test((e as Error).message)) throw e;
  } finally {
    console.log = origLog;
    console.error = origErr;
    process.exit = origExit;
    await control.close();
    for (const [k, v] of Object.entries(prevEnv)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
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

test("parseHandoffArgs: goal, repeated --next, --to, --carry, --worktree", () => {
  const a = parseHandoffArgs([
    "--to", "codex",
    "--goal", "make it idempotent",
    "--next", "down path",
    "--next", "run the suite",
    "--carry", "last:5",
    "--worktree",
  ]);
  assert.equal(a.to, "codex");
  assert.equal(a.goal, "make it idempotent");
  assert.deepEqual(a.next, ["down path", "run the suite"]);
  assert.equal(a.carry, 5);
  assert.equal(a.freshWorktree, true);
});

test("parseHandoffArgs: --carry accepts a bare count as well as last:N", () => {
  assert.equal(parseHandoffArgs(["--carry", "7"]).carry, 7);
  assert.equal(parseHandoffArgs([]).carry, undefined);
});

// ---------------------------------------------------------------------------
// identity comes from the environment (D3) — no positional arguments
// ---------------------------------------------------------------------------

test("outside a makit session it is a usage error, and nothing is created", async () => {
  const r = await run(["--goal", "x"], { env: { MAKIT_SESSION_ID: undefined } });
  assert.equal(r.code, 2);
  assert.match(r.err, /MAKIT_SESSION_ID|inside a makit session/i);
  assert.equal(r.cmds.length, 0);
});

test("the child names the session it was handed off from, so the chain is visible", async () => {
  // An **agent** credential has its parent derived server-side and may not name a
  // different one (D9). A human running `makit handoff` from a terminal has no
  // session of its own, so it states the parent instead — otherwise the child
  // records a reason with no origin, and neither `makit tree` nor the app's
  // "handed off from …" caption has anything to show.
  const r = await run(["--goal", "make it idempotent"]);
  assert.equal(r.code, 0, r.err);
  const spawn = sent(r.cmds, "session.spawn")!;
  assert.equal(spawn.parentId, "parent-sid");
  assert.equal(spawn.projectId, "p1");
});

// ---------------------------------------------------------------------------
// D15 inverse — inherit the parent's tree unless asked otherwise
// ---------------------------------------------------------------------------

test("the child inherits the parent's worktree and branch, creating no tree", async () => {
  const r = await run(["--goal", "x"]);
  assert.equal(sent(r.cmds, "worktree.create"), undefined);
  const spawn = sent(r.cmds, "session.spawn")!;
  assert.equal(spawn.worktreePath, PARENT.worktreePath);
  assert.equal(spawn.branch, PARENT.branch);
});

test("--worktree opts into a fresh tree", async () => {
  const r = await run(["--goal", "x", "--worktree"]);
  assert.ok(sent(r.cmds, "worktree.create"), "a fresh tree was asked for");
  const spawn = sent(r.cmds, "session.spawn")!;
  assert.equal(spawn.worktreePath, "/tmp/repo-wt/fresh");
  assert.equal(spawn.branch, "fresh");
});

test("--to picks the receiving harness", async () => {
  const r = await run(["--goal", "x", "--to", "codex"]);
  assert.equal(sent(r.cmds, "session.spawn")!.agent, "codex");
});

// ---------------------------------------------------------------------------
// the manifest becomes the child's first message
// ---------------------------------------------------------------------------

test("the first message is the rendered manifest, in the fixed section order", async () => {
  const r = await run(["--goal", "make the migration idempotent", "--next", "down path is unimplemented"]);
  const msg = sent(r.cmds, "send.message")!;
  assert.equal(msg.sessionId, "child-sid");
  const text = String(msg.text);
  assert.match(text, /## Goal/);
  assert.match(text, /make the migration idempotent/);
  assert.match(text, /## Next/);
  assert.match(text, /down path is unimplemented/);
  assert.ok(text.indexOf("## Goal") < text.indexOf("## Next"));
});

test("--file reads a manifest an agent wrote, and unknown keys do not reject it", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-manifest-"));
  const f = join(dir, "m.json");
  writeFileSync(
    f,
    JSON.stringify({
      goal: "from a file",
      done: ["schema diff written"],
      gotchas: ["resumeSessionPath is legacy"],
      invented_by_the_llm: "ignored",
    }),
  );
  try {
    const r = await run(["--file", f]);
    const text = String(sent(r.cmds, "send.message")!.text);
    assert.match(text, /from a file/);
    assert.match(text, /schema diff written/);
    assert.match(text, /resumeSessionPath is legacy/);
    assert.doesNotMatch(text, /invented_by_the_llm/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a manifest file that is not JSON is a usage error, not a half-made session", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-manifest-"));
  const f = join(dir, "m.json");
  writeFileSync(f, "this is not json");
  try {
    const r = await run(["--file", f]);
    assert.equal(r.code, 2);
    assert.equal(r.cmds.length, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a manifest file that does not exist is a usage error, not a raw ENOENT", async () => {
  // The producer of `--file` is usually an agent, which mis-paths files. Only
  // JSON.parse was guarded, so a bad path threw a raw Node error with a stack —
  // in an agent's transcript that reads as a crash rather than "fix the path".
  const r = await run(["--file", join(tmpdir(), "makit-no-such-manifest-9f3a.json")]);
  assert.equal(r.code, 2);
  assert.match(r.err, /makit-no-such-manifest-9f3a\.json/, "the message names the file");
  assert.doesNotMatch(r.err, /at .*\.ts:|node:internal/, "no stack trace");
  assert.equal(r.cmds.length, 0, "and nothing is created");
});

test("a manifest file that cannot be read is a usage error too", async () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-manifest-"));
  const f = join(dir, "m.json");
  writeFileSync(f, JSON.stringify({ goal: "x" }), { mode: 0o000 });
  try {
    const r = await run(["--file", f]);
    // Running as root would read it anyway; only assert when the mode bites.
    if (r.code !== 0) {
      assert.equal(r.code, 2);
      assert.doesNotMatch(r.err, /at .*\.ts:|node:internal/, "no stack trace");
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// --carry: a bounded excerpt, fetched with session.transcript (C3/D5)
// ---------------------------------------------------------------------------

test("--carry last:5 fetches exactly 5 events of the PARENT and quotes them", async () => {
  const events = [
    { seq: 11, sessionId: "parent-sid", ts: 1, kind: "user.message", payload: { text: "make it idempotent" } },
    { seq: 12, sessionId: "parent-sid", ts: 2, kind: "agent.message", payload: { text: "looking at the schema" } },
  ];
  const r = await run(["--goal", "x", "--carry", "last:5"], { events });
  const t = sent(r.cmds, "session.transcript")!;
  assert.equal(t.sessionId, "parent-sid");
  assert.equal(t.limit, 5);
  const text = String(sent(r.cmds, "send.message")!.text);
  assert.match(text, /```/, "the excerpt is fenced, so it cannot read as instructions");
  assert.match(text, /looking at the schema/);
  // Quoted context, not agent state: the manifest still leads.
  assert.ok(text.indexOf("## Goal") < text.indexOf("```"));
});

test("without --carry no transcript is read at all", async () => {
  const r = await run(["--goal", "x"]);
  assert.equal(sent(r.cmds, "session.transcript"), undefined);
});

// ---------------------------------------------------------------------------
// D16 — the parent keeps running
// ---------------------------------------------------------------------------

test("the parent is neither archived nor killed", async () => {
  const r = await run(["--goal", "x"]);
  assert.equal(sent(r.cmds, "session.archive"), undefined);
  assert.equal(sent(r.cmds, "session.kill"), undefined);
});

test("the spawn records why the handoff happened (D10)", async () => {
  const r = await run(["--goal", "make it idempotent"]);
  assert.match(String(sent(r.cmds, "session.spawn")!.handoffReason), /make it idempotent/);
});

test("a refused spawn is a clean message, not a stack trace in the agent's shell", async () => {
  // The depth bound (D9) refuses a handoff for real, and the caller is usually an
  // agent's `bash` — so an unhandled rejection here means a wall of node frames in
  // the transcript instead of "the session tree is at its maximum depth of 3".
  const r = await run(["--goal", "x"], { spawnErr: "spawn refused: the session tree is at its maximum depth of 3" });
  assert.notEqual(r.code, 0);
  assert.match(r.err, /maximum depth of 3/);
  assert.doesNotMatch(r.err, /\bat .*\(/, "no stack frames");
  assert.equal(sent(r.cmds, "send.message"), undefined, "and no message is sent to a session that was refused");
});

test("an empty manifest is refused rather than handing over a blank message", async () => {
  // With no --goal/--next/--file and no --carry, the child's first message was the
  // empty string: a session spawned to continue work, told nothing about it. Better
  // to refuse than to hand an agent a blank brief it cannot ask about.
  const r = await run([]);
  assert.equal(r.code, 2);
  assert.match(r.err, /goal|--file|nothing to hand/i);
  assert.equal(sent(r.cmds, "session.spawn"), undefined, "and no session is created");
});

test("--json prints the child's id and nothing else", async () => {
  const r = await run(["--goal", "x", "--json"]);
  assert.equal(r.out, JSON.stringify({ sessionId: "child-sid" }) + "\n");
});
