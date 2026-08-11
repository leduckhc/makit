/**
 * T12 (SPEC-46) — `makit new`: a session is born in the terminal, in its own
 * worktree.
 *
 * D15 is the load-bearing decision here: a session **owns a worktree**, always,
 * not conditionally on `cwd`. Tab groups are keyed by worktree, ports are
 * attributed per branch, and *Wrap up* means "remove the worktree, delete the
 * branch". A CLI that dropped agents into the user's own checkout would mint
 * sessions that cannot be wrapped up, whose ports collide, and whose diff is
 * tangled with the user's uncommitted edits. `--here` is the explicit opt-out.
 *
 * D4 is the other one: `new` **composes** existing commands — `worktree.create`
 * then `session.spawn` then `send.message` — because the first message is what
 * promotes the draft (naming the branch, applying the config picks). There is no
 * `initialPrompt` on the wire and this file must not invent one.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { parseNewArgs, runNew } from "./new.js";
import { cliCredentialPath } from "./client.js";
import { createControlServer, type ControlBackend } from "../daemon/control-server.js";
import { controlSocketPath } from "../daemon/paths.js";
import { startStubWss } from "../../test/support/stub_wss.js";

const P1 = { id: "p1", name: "makit", path: "/tmp/repo-one", pinned: false, lastActivityAt: 0 };
const P2 = { id: "p2", name: "other", path: "/tmp/repo-two", pinned: false, lastActivityAt: 0 };

function stubBackend(): ControlBackend {
  const unused = () => {
    throw new Error("not used by new");
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

async function withHome(fn: () => Promise<void>): Promise<void> {
  const prev = process.env.MAKIT_HOME;
  const home = mkdtempSync(join(tmpdir(), "makit-new-home-"));
  process.env.MAKIT_HOME = home;
  const control = await createControlServer({ socketPath: controlSocketPath(), backend: stubBackend() });
  mkdirSync(home, { recursive: true });
  writeFileSync(cliCredentialPath(), JSON.stringify({ deviceId: "cli-1", label: "cli@h", bearer: "CACHED" }));
  try {
    await fn();
  } finally {
    await control.close();
    if (prev === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prev;
    rmSync(home, { recursive: true, force: true });
  }
}

interface Run {
  out: string;
  err: string;
  code: number;
  cmds: Record<string, unknown>[];
}

/**
 * Run `makit new` against a stub server, recording every command frame it sent.
 * `worktree` is what the stub answers `worktree.create` with — including the
 * degraded `{path: repoPath, branch: null}` a non-git repo or an unborn HEAD
 * produces server-side.
 */
async function run(
  argv: string[],
  opts: {
    projects?: unknown[];
    worktree?: { path: string; branch: string | null };
    refuse?: { kind: string; message: string };
  } = {},
): Promise<Run> {
  const cmds: Record<string, unknown>[] = [];
  const wt = opts.worktree ?? { path: "/tmp/repo-one-wt/fix-the-migration", branch: "fix-the-migration" };
  const stub = await startStubWss({
    acceptBearer: "CACHED",
    projects: opts.projects ?? [P1],
    sessions: [],
    onCmd: (m) => {
      cmds.push(m);
      if (opts.refuse && m.kind === opts.refuse.kind) return { __err: opts.refuse.message };
      if (m.kind === "worktree.create") return { projectId: m.projectId, path: wt.path, branch: wt.branch };
      if (m.kind === "session.spawn") return { sessionId: "new-sid" };
      return {};
    },
  });
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
    await withHome(() => runNew([...argv, "--port", String(stub.port)]));
  } catch (e) {
    if (!/^__exit__:/.test((e as Error).message)) throw e;
  } finally {
    console.log = origLog;
    console.error = origErr;
    process.exit = origExit;
    await stub.close();
  }
  return { out, err, code, cmds };
}

const sent = (cmds: Record<string, unknown>[], kind: string) => cmds.find((c) => c.kind === kind);

// ---------------------------------------------------------------------------
// argv parsing
// ---------------------------------------------------------------------------

test("parseNewArgs: defaults", () => {
  const a = parseNewArgs([]);
  assert.equal(a.host, "127.0.0.1");
  assert.equal(a.port, 7777);
  assert.equal(a.here, false);
  assert.equal(a.json, false);
  assert.equal(a.message, undefined);
  assert.deepEqual(a.configOptions, []);
});

test("parseNewArgs: every flag", () => {
  const a = parseNewArgs([
    "-m", "fix the migration",
    "--agent", "codex",
    "--project", "p2",
    "--branch", "feat/x",
    "--base", "main",
    "--config", "model=opus",
    "--config", "reasoning=high",
    "--json",
  ]);
  assert.equal(a.message, "fix the migration");
  assert.equal(a.agent, "codex");
  assert.equal(a.projectId, "p2");
  assert.equal(a.branch, "feat/x");
  assert.equal(a.base, "main");
  assert.equal(a.json, true);
  assert.deepEqual(a.configOptions, [
    { id: "model", value: "opus" },
    { id: "reasoning", value: "high" },
  ]);
});

// ---------------------------------------------------------------------------
// D15 — a worktree by default, named after the message
// ---------------------------------------------------------------------------

test("-m seeds branchName so the branch is named after the work, not a uuid", async () => {
  const r = await run(["-m", "fix the migration"]);
  assert.equal(r.code, 0, r.err);
  // The CLI passes the message as `branchName`; the server slugifies and
  // de-duplicates it (`slugifyBranch` + `uniqueBranch`), so the CLI must not.
  assert.equal(sent(r.cmds, "worktree.create")!.branchName, "fix the migration");
  const spawn = sent(r.cmds, "session.spawn")!;
  assert.equal(spawn.worktreePath, "/tmp/repo-one-wt/fix-the-migration");
  assert.equal(spawn.branch, "fix-the-migration");
  assert.notEqual(spawn.worktreePath, P1.path); // never the repo dir
});

test("the message is then sent as the first message, which promotes the draft", async () => {
  const r = await run(["-m", "fix the migration"]);
  const msg = sent(r.cmds, "send.message")!;
  assert.equal(msg.sessionId, "new-sid");
  assert.equal(msg.text, "fix the migration");
  // Order matters: worktree, then spawn, then the message that promotes it.
  assert.deepEqual(
    r.cmds.map((c) => c.kind),
    ["worktree.create", "session.spawn", "send.message"],
  );
});

test("without -m the session stays a draft: no send.message, auto branch name", async () => {
  const r = await run([], { worktree: { path: "/tmp/repo-one-wt/worktree-a1b2", branch: "worktree-a1b2" } });
  assert.equal(sent(r.cmds, "worktree.create")!.branchName, undefined);
  assert.equal(sent(r.cmds, "send.message"), undefined);
});

test("--branch overrides the message-derived name, and --base picks the base ref", async () => {
  const r = await run(["-m", "hello", "--branch", "feat/x", "--base", "release/2"]);
  const create = sent(r.cmds, "worktree.create")!;
  assert.equal(create.branchName, "feat/x");
  assert.equal(create.baseBranch, "release/2");
});

test("--here opts out: no worktree is created and the session runs in cwd", async () => {
  const r = await run(["--here", "-m", "hello"]);
  assert.equal(sent(r.cmds, "worktree.create"), undefined);
  assert.equal(sent(r.cmds, "session.spawn")!.worktreePath, process.cwd());
});

test("a non-git project (or unborn HEAD) degrades to the repo dir without an error", async () => {
  // This is what `createWorktree` returns for both cases, server-side.
  const r = await run(["-m", "hello"], { worktree: { path: P1.path, branch: null } });
  assert.equal(r.code, 0, r.err);
  const spawn = sent(r.cmds, "session.spawn")!;
  assert.equal(spawn.worktreePath, P1.path);
  assert.equal(spawn.branch, undefined, "a null branch must be omitted, not sent as null");
});

test("--agent and --config are passed to the spawn", async () => {
  const r = await run(["--agent", "codex", "--config", "model=opus"]);
  const spawn = sent(r.cmds, "session.spawn")!;
  assert.equal(spawn.agent, "codex");
  assert.deepEqual(spawn.configOptions, [{ id: "model", value: "opus" }]);
});

// ---------------------------------------------------------------------------
// project resolution + output contract
// ---------------------------------------------------------------------------

test("with one project no --project is needed", async () => {
  const r = await run(["-m", "hello"]);
  assert.equal(sent(r.cmds, "worktree.create")!.projectId, "p1");
});

test("with several projects and no --project it is a usage error (exit 2)", async () => {
  const r = await run(["-m", "hello"], { projects: [P1, P2] });
  assert.equal(r.code, 2);
  assert.match(r.err, /--project/);
  assert.equal(r.cmds.length, 0, "nothing may be created before the ambiguity is resolved");
});

test("--project accepts a project name as well as an id", async () => {
  const r = await run(["-m", "hello", "--project", "other"], { projects: [P1, P2] });
  assert.equal(sent(r.cmds, "worktree.create")!.projectId, "p2");
});

test("an unknown --project is a usage error (exit 2), not a spawn into nowhere", async () => {
  const r = await run(["-m", "hello", "--project", "nope"], { projects: [P1, P2] });
  assert.equal(r.code, 2);
  assert.equal(r.cmds.length, 0);
});

test("--json prints the wire's own sessionId and nothing else", async () => {
  const r = await run(["-m", "hello", "--json"]);
  assert.equal(r.out, JSON.stringify({ sessionId: "new-sid" }) + "\n");
});

test("human output names the session and the branch it landed on", async () => {
  const r = await run(["-m", "fix the migration"]);
  assert.match(r.out, /new-sid/);
  assert.match(r.out, /fix-the-migration/);
});

// ---------------------------------------------------------------------------
// A half-created session leaves no worktree behind
//
// `new` creates a worktree and *then* spawns, so every refusal of the spawn
// leaves an orphan tree on disk. That refusal is not exotic: it is exactly what
// D9's depth and fan-out bounds return, and the caller they were written for is
// an agent in a retry loop — so the orphans accumulate one per attempt, on the
// path the bound exists to make safe. `spawnFromArgs` is shared with `makit
// run`, so both verbs inherit whatever this does.
// ---------------------------------------------------------------------------

test("a refused session.spawn removes the worktree it had just created", async () => {
  const r = await run(["-m", "hello"], {
    refuse: { kind: "session.spawn", message: "session s1 already has 4 live children" },
  });
  assert.equal(r.code, 1);
  assert.match(r.err, /already has 4 live children/);
  const removed = sent(r.cmds, "worktree.remove");
  assert.ok(removed, "the worktree created for a session that never existed must be removed");
  assert.equal(removed.worktreePath, "/tmp/repo-one-wt/fix-the-migration");
  assert.equal(removed.projectId, "p1");
});

test("--here has no worktree to roll back, so a refused spawn removes nothing", async () => {
  const r = await run(["-m", "hello", "--here"], {
    refuse: { kind: "session.spawn", message: "spawn depth 3 reached" },
  });
  assert.equal(r.code, 1);
  assert.equal(sent(r.cmds, "worktree.remove"), undefined, "the user's own checkout is not ours to remove");
});

test("a rollback that itself fails still reports the original refusal", async () => {
  // The tree may be dirty or already gone; the spawn refusal is the news.
  const r = await run(["-m", "hello"], {
    refuse: { kind: "session.spawn", message: "spawn depth 3 reached" },
  });
  assert.match(r.err, /spawn depth 3 reached/);
});
