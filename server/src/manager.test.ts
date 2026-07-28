import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, mkdirSync, writeFileSync, readdirSync, rmSync, existsSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, basename } from "node:path";

import { SessionManager } from "./manager.js";
import { CapabilityCache } from "./adapters/capability_cache.js";
import { fingerprintAgent } from "./adapters/catalog.js";
import { Session } from "./session.js";
import type { PersistedProject } from "./project-store.js";
import { piSessionsDir } from "./pi-sessions.js";
import { DEFAULT_SESSION_TITLE } from "./protocol.js";
import type { SessionEvent, SessionConfigOption, SessionDTO } from "./protocol.js";
import { SqliteEventStore } from "./storage/sqlite_event_store.js";
import type { AgentAdapter, SpawnOpts } from "./adapters/adapter.js";

/** A stub adapter that records the SpawnOpts it was started with. */
function stubAdapter(started: SpawnOpts[]): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as any).agent = "stub";
  (e as any).capabilities = { resume: true, load: false, list: true, delete: true, fork: false };
  (e as any).agentSessionId = undefined;
  (e as any).start = async (opts: SpawnOpts) => {
    started.push(opts);
    // Adopt (or mint) a native id so the manager persists a resume handle,
    // mirroring the real adapters (SPEC-29).
    (e as any).agentSessionId = opts.resumeAgentSessionId ?? `stub-${opts.sessionId ?? "x"}`;
  };
  (e as any).send = async () => {};
  (e as any).cancel = async () => {};
  (e as any).kill = async () => {};
  return e;
}

function withAgentDir(cwd: string, run: (agentDir: string) => Promise<void>) {
  const agentDir = mkdtempSync(join(tmpdir(), "makit-mgr-"));
  const prev = process.env.MAKIT_PI_AGENT_DIR;
  process.env.MAKIT_PI_AGENT_DIR = agentDir;
  return (async () => {
    try {
      const dir = piSessionsDir(cwd, agentDir);
      mkdirSync(dir, { recursive: true });
      writeFileSync(
        join(dir, "2026-01-01T00-00-00-000Z_sess1.jsonl"),
        [
          JSON.stringify({ type: "session", version: 3, id: "sess1", timestamp: "2026-01-01T00:00:00.000Z", cwd }),
          JSON.stringify({ type: "message", message: { role: "user", content: [{ type: "text", text: "old task" }] } }),
        ].join("\n") + "\n",
      );
      await run(agentDir);
    } finally {
      if (prev === undefined) delete process.env.MAKIT_PI_AGENT_DIR;
      else process.env.MAKIT_PI_AGENT_DIR = prev;
      rmSync(agentDir, { recursive: true, force: true });
    }
  })();
}

test("listRepos issues its per-worktree shells concurrently, not serially (P3)", async () => {
  const cwd = makeGitRepo();
  const bin = mkdtempSync(join(tmpdir(), "makit-fake-gh-"));
  const sync = mkdtempSync(join(tmpdir(), "makit-gh-sync-"));
  const worktrees: string[] = [];
  const prevPath = process.env.PATH;
  const WORKTREE_COUNT = 4; // 4 secondary branches → 4 gh lookups
  try {
    // Each secondary worktree is on its own branch, so listRepos does a
    // findOpenPr (gh) lookup per worktree. The fake gh is a barrier: each
    // invocation drops a marker file, then refuses to exit until all
    // WORKTREE_COUNT markers exist. Concurrent lookups all start, the barrier
    // opens, and everyone returns; a serial loop never gets past the first
    // invocation, which times out and leaves a `timeout-*` marker.
    for (let i = 0; i < WORKTREE_COUNT; i++) {
      const wt = join(bin, `wt-${i}`);
      execFileSync("git", ["worktree", "add", "-q", "-b", `feature-${i}`, wt], { cwd });
      worktrees.push(wt);
    }
    const gh = join(bin, "gh");
    writeFileSync(
      gh,
      [
        `#!/bin/sh`,
        `: > "${sync}/inflight-$$"`,
        `n=0`,
        `while [ "$(ls "${sync}"/inflight-* 2>/dev/null | wc -l)" -lt ${WORKTREE_COUNT} ]; do`,
        `  n=$((n + 1))`,
        `  if [ "$n" -gt 500 ]; then : > "${sync}/timeout-$$"; break; fi`, // ~5s: serial ⇒ fail, not hang
        `  sleep 0.01`,
        `done`,
        `printf "[]\\n"`,
        ``,
      ].join("\n"),
    );
    chmodSync(gh, 0o755);
    process.env.PATH = `${bin}:${prevPath ?? ""}`;

    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const repos = await manager.listRepos({ includePrs: true });

    // Results are unchanged: every worktree is present with its branch.
    const branches = repos[0].worktrees.map((w) => w.branch).filter(Boolean).sort();
    for (let i = 0; i < WORKTREE_COUNT; i++) {
      assert.ok(branches.includes(`feature-${i}`), `feature-${i} listed`);
    }
    // Concurrent: all lookups were in flight together, so the barrier opened
    // and no invocation timed out waiting for the others.
    const markers = readdirSync(sync).sort();
    assert.equal(
      markers.filter((m) => m.startsWith("inflight-")).length,
      WORKTREE_COUNT,
      `expected ${WORKTREE_COUNT} gh invocations, saw: ${markers.join(", ")}`,
    );
    assert.deepEqual(
      markers.filter((m) => m.startsWith("timeout-")),
      [],
      "a gh lookup timed out at the barrier — lookups did not overlap (serial?)",
    );
  } finally {
    if (prevPath === undefined) delete process.env.PATH;
    else process.env.PATH = prevPath;
    for (const wt of worktrees) execFileSync("git", ["worktree", "remove", "--force", wt], { cwd });
    rmSync(bin, { recursive: true, force: true });
    rmSync(sync, { recursive: true, force: true });
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("pi threads agent=pi through the adapter factory (headless, ACP)", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const agents: string[] = [];
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: (ctx) => {
        agents.push(ctx.agent);
        return stubAdapter([]);
      },
    });
    const projectId = manager.listProjects()[0].id;
    await manager.spawnSession(projectId, "t", "pi"); // explicit pi (ACP via pi-acp)
    assert.deepEqual(agents, ["pi"]);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnSession threads the chosen agent id into the adapter factory", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const agents: string[] = [];
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: (ctx) => {
        agents.push(ctx.agent);
        return stubAdapter([]);
      },
    });
    const projectId = manager.listProjects()[0].id;

    await manager.spawnSession(projectId, "t", "codex");
    await manager.spawnSession(projectId, "t"); // default agent (pi)

    assert.deepEqual(agents, ["codex", "pi"]);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("listAgents exposes pi (ACP via pi-acp) when both binaries resolve, and never a pi-acp id", () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  const binDir = mkdtempSync(join(tmpdir(), "makit-bin-"));
  const piAcp = join(binDir, "pi-acp");
  const pi = join(binDir, "pi");
  writeFileSync(piAcp, "#!/bin/sh\n");
  writeFileSync(pi, "#!/bin/sh\n");
  chmodSync(piAcp, 0o755);
  chmodSync(pi, 0o755);
  const savedAcp = process.env.MAKIT_PI_ACP_BIN;
  const savedPi = process.env.MAKIT_PI_BIN;
  process.env.MAKIT_PI_ACP_BIN = piAcp;
  process.env.MAKIT_PI_BIN = pi;
  try {
    const manager = new SessionManager({ projects: [cwd] });
    const agents = manager.listAgents();
    const entry = agents.find((a) => a.id === "pi");
    assert.ok(entry, "pi should be listed");
    assert.equal(entry!.transport, "acp");
    // pi is the agent id on the wire; there is no separate "pi-acp" id.
    assert.ok(!agents.some((a) => a.id === "pi-acp"));
  } finally {
    if (savedAcp === undefined) delete process.env.MAKIT_PI_ACP_BIN;
    else process.env.MAKIT_PI_ACP_BIN = savedAcp;
    if (savedPi === undefined) delete process.env.MAKIT_PI_BIN;
    else process.env.MAKIT_PI_BIN = savedPi;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(binDir, { recursive: true, force: true });
  }
});

/** Init a throwaway git repo with one commit on `main`. */
function makeGitRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), "makit-repo-"));
  const g = (...args: string[]) => execFileSync("git", args, { cwd: dir });
  g("init", "-q", "-b", "main");
  g("config", "user.email", "t@t.io");
  g("config", "user.name", "Test");
  writeFileSync(join(dir, "README.md"), "hello\n");
  g("add", ".");
  g("commit", "-q", "-m", "init");
  return dir;
}

test("createWorktree then renameWorktreeBranch renames the branch", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId);
    assert.ok(wt.branch);
    await manager.renameWorktreeBranch(projectId, wt.path, "renamed-branch");
    const branch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: wt.path })
      .toString()
      .trim();
    assert.equal(branch, "renamed-branch");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("createWorktree uses a sanitized branch name when one is supplied", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "My Feature!");
    assert.equal(wt.branch, "my-feature");
    const branch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: wt.path })
      .toString()
      .trim();
    assert.equal(branch, "my-feature");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("createWorktree keeps every word of an explicit branch name", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    // Seven words: the 6-word cap for message-derived names must not truncate
    // a name the user typed on purpose.
    const wt = await manager.createWorktree(projectId, undefined, "add user auth flow with oauth jwt");
    assert.equal(wt.branch, "add-user-auth-flow-with-oauth-jwt");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("createWorktree preserves slashes in the branch but flattens the directory", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "feat/new-ui");
    // Branch keeps its hierarchy...
    assert.equal(wt.branch, "feat/new-ui");
    const branch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: wt.path })
      .toString()
      .trim();
    assert.equal(branch, "feat/new-ui");
    // ...but the worktree directory is flattened (no nested subfolder).
    assert.equal(basename(wt.path), "feat-new-ui");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("createWorktree falls back to an auto name when the supplied name is blank", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "   ");
    assert.ok(wt.branch);
    assert.match(wt.branch as string, /^worktree-/);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("removeWorktree deletes the worktree from disk", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId);
    assert.ok(existsSync(wt.path));
    await manager.removeWorktree(projectId, wt.path);
    assert.equal(existsSync(wt.path), false);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("removeWorktree preserves archived sessions and auto-archives live ones (SPEC-29)", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => stubAdapter([]),
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId);

    // Two sessions bound to the worktree: one already archived, one live.
    const draftA = await manager.spawnPendingSession(projectId, "pi", undefined, wt.path);
    await manager.promotePendingSession(draftA, "archived one");
    await manager.archiveSession(draftA.id);

    const draftB = await manager.spawnPendingSession(projectId, "pi", undefined, wt.path);
    await manager.promotePendingSession(draftB, "live one");
    assert.equal(manager.getSession(draftB.id)!.archived, false);

    await manager.removeWorktree(projectId, wt.path);

    // Neither was destroyed: both survive as archived sessions.
    assert.equal(manager.getSession(draftA.id)!.archived, true); // preserved
    assert.equal(manager.getSession(draftB.id)!.archived, true); // auto-archived
    // Both are hidden from the active list.
    const active = manager.listSessions().map((d) => d.id);
    assert.ok(!active.includes(draftA.id));
    assert.ok(!active.includes(draftB.id));
    // Both appear in the archived list, flagged orphaned (worktree removed).
    const archived = await manager.listArchivedSessions();
    const a = archived.find((d) => d.id === draftA.id)!;
    const b = archived.find((d) => d.id === draftB.id)!;
    assert.equal(a.orphaned, true);
    assert.equal(b.orphaned, true);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
    store.close();
  }
});

test("unarchive of an orphaned session detaches it to the repo root (SPEC-29)", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const cwd = realpathSync(makeGitRepo());
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => stubAdapter([]),
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId);

    const draft = await manager.spawnPendingSession(projectId, "pi", undefined, wt.path);
    await manager.promotePendingSession(draft, "orphan me");
    assert.equal(manager.getSession(draft.id)!.worktreePath !== undefined, true);

    // Deleting the worktree auto-archives the session, flagged orphaned.
    await manager.removeWorktree(projectId, wt.path);
    assert.equal((await manager.listArchivedSessions()).find((d) => d.id === draft.id)!.orphaned, true);

    // Restore: it returns to the ACTIVE list, detached to the repo root — its
    // stale worktree path is cleared so it renders under the primary worktree.
    await manager.unarchiveSession(draft.id);
    const restored = manager.getSession(draft.id)!;
    assert.equal(restored.archived, false);
    assert.equal(restored.worktreePath, undefined, "orphaned worktree path is cleared");
    assert.equal(restored.branch, undefined, "orphaned branch is cleared");
    assert.ok(manager.listSessions().some((d) => d.id === draft.id), "back in active list");

    // The repo snapshot buckets it under the repo root (primary worktree), so
    // the sidebar can render it (it was previously in no worktree's sessionIds).
    const repos = await manager.listRepos();
    const snap = repos.find((r) => r.id === projectId)!;
    const primary = snap.worktrees.find((w) => w.isPrimary)!;
    assert.ok(primary.sessionIds.includes(draft.id), "restored session buckets under repo root");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
    store.close();
  }
});

test("unarchive of a session whose worktree is still live preserves its binding (SPEC-29)", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const cwd = realpathSync(makeGitRepo());
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => stubAdapter([]),
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId);

    const draft = await manager.spawnPendingSession(projectId, "pi", undefined, wt.path);
    await manager.promotePendingSession(draft, "keep me");
    const before = manager.getSession(draft.id)!;
    const boundPath = before.worktreePath;
    const boundBranch = before.branch;
    assert.ok(boundPath !== undefined, "session is bound to the worktree");

    // Archive WITHOUT removing the worktree, so the recorded path stays live.
    await manager.archiveSession(draft.id);
    assert.equal((await manager.listArchivedSessions()).find((d) => d.id === draft.id)!.orphaned, false);

    // Restore must NOT detach: the worktree is still a live worktree, so the
    // binding is preserved (only a genuinely-absent worktree detaches to root).
    await manager.unarchiveSession(draft.id);
    const restored = manager.getSession(draft.id)!;
    assert.equal(restored.archived, false);
    assert.equal(restored.worktreePath, boundPath, "live worktree path is preserved");
    assert.equal(restored.branch, boundBranch, "live branch is preserved");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
    store.close();
  }
});

test("renameWorktreeBranch refuses the repo's primary worktree", async () => {
  const cwd = makeGitRepo();
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    await assert.rejects(
      () => manager.renameWorktreeBranch(projectId, realpathSync(cwd), "renamed"),
      /primary worktree/,
    );
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("removeWorktree refuses the repo's primary worktree", async () => {
  const cwd = makeGitRepo();
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    await assert.rejects(
      () => manager.removeWorktree(projectId, realpathSync(cwd)),
      /primary worktree/,
    );
    // The primary checkout is untouched.
    assert.equal(existsSync(cwd), true);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("removeWorktree refuses a path that is not one of the project's worktrees", async () => {
  const cwd = makeGitRepo();
  const stranger = mkdtempSync(join(tmpdir(), "makit-stranger-"));
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    await assert.rejects(
      () => manager.removeWorktree(projectId, stranger),
      /not part of project/,
    );
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    rmSync(stranger, { recursive: true, force: true });
  }
});

test("createWorktreeFromPr rejects a PR that is not open on this repo", async () => {
  const cwd = makeGitRepo();
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    // The throwaway repo has no GitHub remote, so listOpenPrs yields [] and the
    // lookup for any PR number fails rather than silently creating a worktree.
    await assert.rejects(
      () => manager.createWorktreeFromPr(projectId, 999999),
      /not an open PR/,
    );
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnPendingSession is a draft: no worktree, no agent started", async () => {
  const cwd = makeGitRepo();
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    const s = await manager.spawnPendingSession(projectId, "pi");
    assert.equal(s.pending, true);
    assert.equal(started.length, 0, "no adapter should start for a draft");
    assert.equal(s.toDTO().pending, true);
    assert.equal(s.toDTO().branch, undefined);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

/** A stub adapter that records SpawnOpts + configOption actions applied to it. */
function stubActionAdapter(
  started: SpawnOpts[],
  actions: { action: string; args?: Record<string, unknown> }[],
): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as any).agent = "stub";
  (e as any).start = async (opts: SpawnOpts) => {
    started.push(opts);
  };
  (e as any).send = async () => {};
  (e as any).cancel = async () => {};
  (e as any).kill = async () => {};
  (e as any).sendAction = async (action: string, args?: Record<string, unknown>) => {
    actions.push({ action, args });
  };
  return e;
}

/** A capability cache pre-warmed with a fixed catalog for `agentId`. */
function warmCache(agentId: string, configOptions: SessionConfigOption[]): CapabilityCache {
  const cache = new CapabilityCache({
    path: join(mkdtempSync(join(tmpdir(), "makit-capm-")), "cache.json"),
    prober: async () => configOptions,
  });
  cache.set(agentId, { fingerprint: fingerprintAgent(agentId), configOptions });
  return cache;
}

const PI_CATALOG: SessionConfigOption[] = [
  {
    id: "model",
    name: "Model",
    category: "model",
    type: "select",
    currentValue: "gpt-5",
    options: [
      { value: "gpt-5", name: "GPT-5" },
      { value: "o3", name: "o3" },
    ],
  },
  { id: "web", name: "Web", category: "_tools", type: "boolean", currentValue: false },
];

test("startPendingSession applies valid config picks to the real adapter and drops invalid ones", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const actions: { action: string; args?: Record<string, unknown> }[] = [];
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: () => stubActionAdapter(started, actions),
      capabilityCache: warmCache("pi", PI_CATALOG),
    });
    const projectId = manager.listProjects()[0].id;

    const draft = await manager.spawnPendingSession(projectId, "pi", undefined, undefined, undefined, [
      { id: "model", value: "o3" },
      { id: "web", value: true },
      { id: "model", value: "nope" },
      { id: "ghost", value: "x" },
    ]);
    await manager.startPendingSession(draft.id, "Configure the model");

    // Only the two valid picks reached the real adapter, applied AFTER start.
    assert.equal(started.length, 1);
    assert.deepEqual(actions, [
      { action: "configOption", args: { id: "model", value: "o3" } },
      { action: "configOption", args: { id: "web", value: true } },
    ]);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("a draft with no picks applies no configOption actions at launch", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const actions: { action: string; args?: Record<string, unknown> }[] = [];
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: () => stubActionAdapter(started, actions),
      capabilityCache: warmCache("pi", PI_CATALOG),
    });
    const projectId = manager.listProjects()[0].id;
    const draft = await manager.spawnPendingSession(projectId, "pi");
    await manager.startPendingSession(draft.id, "Just start");
    assert.equal(actions.length, 0);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("startPendingSession creates a worktree named from the first message and starts the agent there", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    const draft = await manager.spawnPendingSession(projectId, "pi");
    const s = await manager.startPendingSession(draft.id, "Add a login form to the app");

    assert.equal(s.pending, false);
    assert.equal(s.branch, "add-a-login-form-to-the");
    assert.ok(s.worktreePath?.startsWith(realpathSync(base)), `worktree ${s.worktreePath} under ${base}`);
    assert.equal(started.length, 1, "agent should start once");
    assert.equal(started[0]?.cwd, s.worktreePath, "agent runs in the worktree");

    const repos = await manager.listRepos();
    const wt = repos[0].worktrees.find((w) => w.branch === "add-a-login-form-to-the");
    assert.ok(wt, "worktree should be listed");
    assert.deepEqual(wt!.sessionIds, [s.id], "session linked to its worktree");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("startPendingSession forks the worktree off the chosen base branch", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    // A second branch `dev` with a file that does not exist on `main`.
    const g = (...args: string[]) => execFileSync("git", args, { cwd });
    g("checkout", "-q", "-b", "dev");
    writeFileSync(join(cwd, "dev.txt"), "dev\n");
    g("add", ".");
    g("commit", "-q", "-m", "dev-only");
    g("checkout", "-q", "main");

    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    const draft = await manager.spawnPendingSession(projectId, "pi", "dev");
    const s = await manager.startPendingSession(draft.id, "work off dev");
    // The worktree forked off `dev`, so the dev-only file is present.
    assert.equal(existsSync(join(s.worktreePath!, "dev.txt")), true, "worktree forked off dev");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("startPendingSession falls back to the default branch for an unknown base", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    const draft = await manager.spawnPendingSession(projectId, "pi", "no-such-branch");
    const s = await manager.startPendingSession(draft.id, "work");
    // Falls back to `main`: the worktree exists and the agent started.
    assert.ok(s.worktreePath?.startsWith(realpathSync(base)));
    assert.equal(started.length, 1);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("spawnPendingSession binds an existing worktree (branch from git) and rejects foreign paths", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    // + New worktree: create the worktree up front.
    const wt = await manager.createWorktree(projectId);
    assert.ok(wt.branch, "created worktree has a branch");
    // Independently read the worktree's branch from git so the assertions
    // below prove derivation from git, not just agreement with the manager.
    const gitBranch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
      cwd: wt.path,
    })
      .toString()
      .trim();

    // A path that is not a worktree of this project is rejected.
    await assert.rejects(
      () => manager.spawnPendingSession(projectId, "pi", undefined, "/tmp/definitely-not-a-worktree"),
      /not part of project/,
    );

    // Binding a real worktree derives the branch from git, ignoring the
    // client-supplied branch arg.
    const draft = await manager.spawnPendingSession(projectId, "pi", undefined, wt.path, "client-lied");
    assert.equal(draft.branch, gitBranch, "branch derived from git, not the client");

    // First message starts the agent IN the bound worktree (no new tree).
    const s = await manager.startPendingSession(draft.id, "do work");
    assert.equal(s.worktreePath, wt.path);
    assert.equal(s.branch, gitBranch);
    assert.equal(started[0]?.cwd, wt.path, "agent runs in the bound worktree");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("removeWorktree kills drafts still bound to the tree (pendingWorktreePath)", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId);
    // A draft bound to the worktree: its path lives on lifecycle.pendingWorktreePath
    // (session.worktreePath is undefined until the draft is started).
    const draft = await manager.spawnPendingSession(projectId, "pi", undefined, wt.path);
    assert.ok(manager.getSession(draft.id));
    assert.equal(draft.worktreePath, undefined);

    await manager.removeWorktree(projectId, wt.path);

    // The draft is gone (would otherwise later start an agent in a deleted dir).
    assert.equal(manager.getSession(draft.id), undefined);
    assert.equal(existsSync(wt.path), false);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("removeWorktree keeps sessions alive when the git removal fails", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId);
    const draft = await manager.spawnPendingSession(projectId, "pi", undefined, wt.path);
    assert.ok(manager.getSession(draft.id));
    // Lock the worktree so a single `--force` removal fails (git requires
    // `-f -f` for locked trees) — a deterministic stand-in for any git
    // administrative failure.
    execFileSync("git", ["worktree", "lock", wt.path], { cwd });

    await assert.rejects(() => manager.removeWorktree(projectId, wt.path));

    // Removal failed, so the session must NOT have been killed and the worktree
    // must still exist.
    assert.ok(manager.getSession(draft.id), "session survives a failed removal");
    assert.equal(existsSync(wt.path), true);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("spawnLinkedSession shares one virtual worktree across two drafts", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    // A plain draft (no worktree yet), then split it into a sibling draft.
    const d1 = await manager.spawnPendingSession(projectId, "pi");
    const d2 = await manager.spawnLinkedSession(d1.id);
    assert.notEqual(d1.id, d2.id);
    assert.equal(d2.pending, true, "the linked session is itself a draft");

    // The sibling (d2) sends first: it forks the shared worktree.
    const s2 = await manager.startPendingSession(d2.id, "add login form");
    assert.ok(s2.worktreePath?.startsWith(realpathSync(base)));
    // The original (d1) sends later: it reuses the SAME tree, not a new one.
    const s1 = await manager.startPendingSession(d1.id, "a totally different task");
    assert.equal(s1.worktreePath, s2.worktreePath, "both drafts share one worktree");
    assert.equal(s1.branch, s2.branch, "both drafts share one branch");

    // Exactly one worktree was forked (one extra beyond the primary checkout).
    const repos = await manager.listRepos();
    const forked = repos[0].worktrees.filter((w) => w.branch === s2.branch);
    assert.equal(forked.length, 1, "only one shared worktree exists");
    assert.deepEqual(
      [...(forked[0]!.sessionIds ?? [])].sort(),
      [s1.id, s2.id].sort(),
      "both sessions link to the shared worktree",
    );
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("spawnLinkedSession mirrors a started session's real worktree", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    // Start a session so it has a real worktree, then split off it.
    const d1 = await manager.spawnPendingSession(projectId, "pi");
    const s1 = await manager.startPendingSession(d1.id, "first task");
    const d2 = await manager.spawnLinkedSession(s1.id);
    const s2 = await manager.startPendingSession(d2.id, "second task");

    assert.equal(s2.worktreePath, s1.worktreePath, "linked session reuses the real worktree");
    assert.equal(s2.branch, s1.branch);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("startPendingSession is idempotent for a live session", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;
    const draft = await manager.spawnPendingSession(projectId, "pi");
    const s1 = await manager.startPendingSession(draft.id, "fix bug");
    const s2 = await manager.startPendingSession(draft.id, "fix bug again");
    assert.equal(s1.id, s2.id);
    assert.equal(started.length, 1, "second call must not start another agent");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("promotePendingSession collapses two concurrent first messages onto one worktree/adapter", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;
    const draft = await manager.spawnPendingSession(projectId, "pi");

    // Two first messages fired concurrently must NOT each fork a worktree +
    // adapter — they collapse onto one in-flight promotion.
    const [r1, r2] = await Promise.all([
      manager.promotePendingSession(draft, "add a login form"),
      manager.promotePendingSession(draft, "add a login form"),
    ]);

    assert.equal(r1, true);
    assert.equal(r2, true);
    assert.equal(started.length, 1, "exactly one adapter started for concurrent promotions");
    assert.equal(draft.pending, false);

    // Exactly one non-root worktree was created for this project.
    const repos = await manager.listRepos();
    const extraWorktrees = repos[0].worktrees.filter((w) => w.path !== realpathSync(cwd) && w.path !== cwd);
    assert.equal(extraWorktrees.length, 1, "exactly one worktree created");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("attachPiSession backfills history, resumes via path, and dedups", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      const started: SpawnOpts[] = [];
      const manager = new SessionManager({
        projects: [cwd],
        adapterFactory: () => stubAdapter(started),
      });
      const projectId = manager.listProjects()[0].id;

      const metas = manager.listPiSessions(projectId);
      assert.equal(metas.length, 1);
      assert.equal(metas[0].piSessionId, "sess1");
      assert.equal(metas[0].preview, "old task");

      const session = await manager.attachPiSession(projectId, "sess1");
      // History was backfilled before the adapter went live.
      assert.equal(session.events[0].kind, "user.message");
      assert.equal(session.events[0].payload.text, "old task");
      // Resumed by path, not a fresh session-id.
      assert.equal(started.length, 1);
      assert.ok(started[0].resumeSessionPath?.endsWith("sess1.jsonl"));

      // Attaching the same pi session again returns the SAME makit session.
      const again = await manager.attachPiSession(projectId, "sess1");
      assert.equal(again.id, session.id);
      assert.equal(started.length, 1);
    });
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("addProject dedupes by resolved path and fires onProjectsChanged", () => {
  const a = mkdtempSync(join(tmpdir(), "makit-proj-"));
  const b = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const changes: PersistedProject[][] = [];
    const manager = new SessionManager({
      projects: [a],
      onProjectsChanged: (projects) => changes.push(projects),
    });

    const first = manager.addProject(b);
    assert.equal(manager.listProjects().length, 2);
    assert.deepEqual(
      changes.at(-1)?.map((p) => p.path),
      [a, b],
    );

    const again = manager.addProject(b + "/");
    assert.equal(again.id, first.id);
    assert.equal(manager.listProjects().length, 2);
    assert.equal(changes.length, 1);
  } finally {
    rmSync(a, { recursive: true, force: true });
    rmSync(b, { recursive: true, force: true });
  }
});

test("restored {id, path} projects keep their id (stable across restart)", () => {
  const a = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    // Simulate a restart: the persistence layer hands back the id it stored.
    const m1 = new SessionManager({ projects: [a] });
    const persistedId = m1.listProjects()[0].id;

    const m2 = new SessionManager({ projects: [{ id: persistedId, path: a }] });
    assert.equal(m2.listProjects()[0].id, persistedId);
    assert.equal(m2.listProjects()[0].path, a);
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("removeProject removes the entry and fires onProjectsChanged", () => {
  const a = mkdtempSync(join(tmpdir(), "makit-proj-"));
  const b = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const changes: PersistedProject[][] = [];
    const manager = new SessionManager({
      projects: [a, b],
      onProjectsChanged: (projects) => changes.push(projects),
    });
    const target = manager.listProjects()[0];

    manager.removeProject(target.id);
    assert.equal(manager.listProjects().length, 1);
    assert.ok(!manager.listProjects().some((p) => p.id === target.id));
    assert.equal(changes.length, 1);
    assert.equal(changes[0].length, 1);
  } finally {
    rmSync(a, { recursive: true, force: true });
    rmSync(b, { recursive: true, force: true });
  }
});

test("removeProject throws on an unknown id", () => {
  const a = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const manager = new SessionManager({ projects: [a] });
    assert.throws(() => manager.removeProject("nope"));
  } finally {
    rmSync(a, { recursive: true, force: true });
  }
});

test("attachPiSession rejects an unknown pi session id", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
      const projectId = manager.listProjects()[0].id;
      await assert.rejects(() => manager.attachPiSession(projectId, "does-not-exist"));
    });
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("killSession kills the adapter, drops it from the registry, and errors on unknown id", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      let killed = 0;
      const manager = new SessionManager({
        projects: [cwd],
        adapterFactory: () => {
          const a = stubAdapter([]);
          (a as any).kill = async () => {
            killed++;
          };
          return a;
        },
      });
      const projectId = manager.listProjects()[0].id;
      const session = await manager.spawnPiSession(projectId);
      assert.ok(manager.getSession(session.id));

      await manager.killSession(session.id);
      assert.equal(killed, 1);
      assert.equal(manager.getSession(session.id), undefined);
      assert.equal(manager.listSessions().length, 0);

      await assert.rejects(() => manager.killSession("nope"));
    });
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("spawnPiSession without an explicit title uses the shared default", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      const manager = new SessionManager({
        projects: [cwd],
        adapterFactory: () => stubAdapter([]),
      });
      const projectId = manager.listProjects()[0].id;
      const session = await manager.spawnPiSession(projectId);
      assert.equal(session.title, DEFAULT_SESSION_TITLE);
    });
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("rehydration is lazy: events are not read from the store until first access", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  store.saveSession({
    id: "sess-lazy",
    projectId: "proj-x",
    agent: "pi",
    title: "big history",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 2,
    lastPreview: "old task",
  });
  store.append("sess-lazy", { ts: 2, kind: "user.message", payload: { text: "old task" } });
  store.append("sess-lazy", { ts: 3, kind: "agent.message", payload: { text: "done" } });

  let reads = 0;
  const counting: typeof store = Object.create(store);
  counting.read = (id: string, fromSeq?: number) => {
    reads++;
    return store.read(id, fromSeq);
  };

  const mgr = new SessionManager({ projects: [], store: counting });
  const session = mgr.getSession("sess-lazy")!;
  assert.equal(reads, 0, "boot must not read any event history");
  // Meta-derived fields are intact without touching the log.
  assert.equal(session.toDTO().lastPreview, "old task");

  // First access loads the history exactly once.
  assert.equal(session.events.length, 2);
  assert.equal(session.events[0].payload.text, "old task");
  assert.equal(reads, 1);
  session.events;
  assert.equal(reads, 1, "history is loaded once, then cached");
  store.close();
});

test("a lazily-rehydrated session that records a new event keeps history + new event in order", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  store.saveSession({
    id: "sess-lazy2",
    projectId: "proj-x",
    agent: "pi",
    title: "t",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 2,
    lastPreview: "old",
  });
  store.append("sess-lazy2", { ts: 2, kind: "user.message", payload: { text: "old" } });

  const mgr = new SessionManager({ projects: [], store });
  const session = mgr.getSession("sess-lazy2")!;
  // Recording without ever touching .events (cold session error path) must not
  // drop or duplicate the persisted history.
  session.adapter.emit("event", { ts: 5, kind: "agent.message", payload: { text: "new" } });
  assert.deepEqual(session.events.map((e) => e.seq), [1, 2]);
  assert.deepEqual(store.read("sess-lazy2").map((e) => e.payload.text), ["old", "new"]);
  store.close();
});

test("rehydrates persisted sessions on boot as read-only history", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  // Seed a session + one event as if a prior server run had persisted them.
  store.saveSession({
    id: "sess-persist",
    projectId: "proj-x",
    agent: "pi",
    title: "resumed work",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 2,
    lastPreview: "old task",
  });
  store.append("sess-persist", { ts: 2, kind: "user.message", payload: { text: "old task" } });

  const mgr = new SessionManager({ projects: [], store });
  const dto = mgr.getSession("sess-persist")?.toDTO();
  assert.ok(dto, "session rehydrated");
  assert.equal(dto!.title, "resumed work");
  assert.equal(dto!.status, "exited");
  assert.equal(mgr.getSession("sess-persist")!.events.length, 1);

  // Sending to a cold session surfaces a re-attach error rather than crashing.
  const errs: string[] = [];
  mgr.getSession("sess-persist")!.on("event", (e) => {
    if (e.kind === "session.error") errs.push(String((e.payload as any).message));
  });
  await mgr.getSession("sess-persist")!.sendUserMessage("hi again");
  assert.match(errs[0] ?? "", /re-attach/);
  store.close();
});

test("branch + worktreePath survive a restart (rehydrated session keeps them)", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  // --- first run: a live session gets promoted onto a worktree.
  const started: SpawnOpts[] = [];
  const live = new Session({ projectId: "proj-x", agent: "pi", adapter: stubAdapter(started), store });
  live.markStarted({ branch: "feature-x", worktreePath: "/tmp/wt" });

  // --- restart: a fresh manager over the same store rehydrates it cold.
  const mgr = new SessionManager({ projects: [], store });
  const cold = mgr.getSession(live.id)!;
  assert.equal(cold.branch, "feature-x");
  assert.equal(cold.worktreePath, "/tmp/wt");
  assert.equal(cold.toDTO().branch, "feature-x");
  assert.equal(cold.toDTO().worktreePath, "/tmp/wt");
  store.close();
});

test("reattachSession resumes in the session's worktree, not the project root", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const projectDir = makeGitRepo();
  // realpath: git reports /private/var/... on macOS while mkdtemp returns the
  // /var/... symlink, and the manager compares resolved (not deref'd) paths.
  const worktreeParent = realpathSync(mkdtempSync(join(tmpdir(), "makit-wt-")));
  const worktreeDir = join(worktreeParent, "feature-x");
  execFileSync("git", ["worktree", "add", "-q", "-b", "feature-x", worktreeDir], { cwd: projectDir });
  const impostorDir = mkdtempSync(join(tmpdir(), "makit-impostor-"));
  try {
    // A prior run left a worktreed pi session with a resume transcript.
    store.saveSession({
      id: "sess-wt",
      projectId: "proj-x",
      agent: "pi",
      title: "worktreed",
      status: "idle",
      policy: "ask-on-risky",
      createdAt: 1,
      lastActivityAt: 2,
      lastPreview: "",
      resumeSessionPath: "/tmp/transcript.jsonl",
      agentSessionId: "acp-sess-wt",
      branch: "feature-x",
      worktreePath: worktreeDir,
    });
    // A sibling session whose persisted path exists on disk but is NOT one of
    // the project's worktrees (e.g. pruned, then the path was recreated).
    store.saveSession({
      id: "sess-impostor",
      projectId: "proj-x",
      agent: "pi",
      title: "impostor",
      status: "idle",
      policy: "ask-on-risky",
      createdAt: 1,
      lastActivityAt: 2,
      lastPreview: "",
      resumeSessionPath: "/tmp/transcript.jsonl",
      agentSessionId: "acp-sess-impostor",
      branch: "gone",
      worktreePath: impostorDir,
    });

    const started: SpawnOpts[] = [];
    const factoryPaths: string[] = [];
    const mgr = new SessionManager({
      projects: [projectDir],
      store,
      adapterFactory: (opts) => {
        factoryPaths.push(opts.projectPath);
        return stubAdapter(started);
      },
    });
    const live = await mgr.reattachSession("sess-wt");
    assert.equal(live.worktreePath, worktreeDir);
    assert.deepEqual(factoryPaths, [worktreeDir]);
    assert.equal(started[0].cwd, worktreeDir);

    // A path that is not an active worktree of the project is NOT reused as
    // cwd, even though it exists on disk.
    await mgr.reattachSession("sess-impostor");
    assert.equal(started[1].cwd, resolve(projectDir));

    // A vanished worktree falls back to the project path.
    rmSync(worktreeDir, { recursive: true, force: true });
    await mgr.reattachSession("sess-wt");
    assert.equal(started[2].cwd, resolve(projectDir));
  } finally {
    rmSync(projectDir, { recursive: true, force: true });
    rmSync(worktreeParent, { recursive: true, force: true });
    rmSync(impostorDir, { recursive: true, force: true });
    store.close();
  }
});

test("reattachSession resumes a cold pi session and continues the durable seq space", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    await withAgentDir(cwd, async () => {
      // --- first run: attach a prior pi transcript so a resume path persists.
      const mgr1 = new SessionManager({
        projects: [cwd],
        store,
        adapterFactory: () => stubAdapter([]),
      });
      const projectId = mgr1.listProjects()[0].id;
      const s = await mgr1.attachPiSession(projectId, "sess1");
      const sessionId = s.id;
      // A live turn after attach.
      s.adapter.emit("event", { ts: 10, kind: "user.message", payload: { text: "live turn" } });
      const maxSeq1 = store.read(sessionId).at(-1)!.seq;
      assert.ok(maxSeq1 >= 2);

      // --- restart: a fresh manager over the same store rehydrates it cold.
      const started: SpawnOpts[] = [];
      const mgr2 = new SessionManager({
        projects: [cwd],
        store,
        adapterFactory: () => stubAdapter(started),
      });
      const cold = mgr2.getSession(sessionId)!;
      assert.equal(cold.status, "exited");
      assert.equal(cold.events.length, maxSeq1); // full history intact

      // Re-attach: rebuild a live adapter and continue.
      const live = await mgr2.reattachSession(sessionId);
      assert.equal(live.id, sessionId);
      assert.equal(started.length, 1); // adapter really started
      assert.equal(started[0].resumeAgentSessionId !== undefined, true); // resumed via native id (SPEC-29)

      // A new event must get the NEXT seq (no reset / collision).
      live.adapter.emit("event", { ts: 20, kind: "user.message", payload: { text: "after reattach" } });
      const seqs = store.read(sessionId).map((e) => e.seq);
      assert.deepEqual(seqs, [...Array(maxSeq1 + 1)].map((_, i) => i + 1));
      assert.equal(live.events.length, maxSeq1 + 1);
    });
  } finally {
    store.close();
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("reattachSession refuses a cold session with no resume path; it stays history-only", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  store.saveSession({
    id: "sess-noresume",
    projectId: "proj-x",
    agent: "pi",
    title: "no resume path",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 2,
    lastPreview: "old",
  });
  store.append("sess-noresume", { ts: 2, kind: "user.message", payload: { text: "old" } });

  const mgr = new SessionManager({ projects: [], store });
  await assert.rejects(() => mgr.reattachSession("sess-noresume"), /history only|resume/);
  await assert.rejects(() => mgr.reattachSession("does-not-exist"), /no such session/);

  // Still cold: sending surfaces the re-attach error rather than crashing.
  const errs: string[] = [];
  mgr.getSession("sess-noresume")!.on("event", (e) => {
    if (e.kind === "session.error") errs.push(String((e.payload as any).message));
  });
  await mgr.getSession("sess-noresume")!.sendUserMessage("hi");
  assert.match(errs[0] ?? "", /re-attach/);
  store.close();
});

test("enrichPrs fills PR info on a git-only snapshot without redoing diff work", async () => {
  const cwd = makeGitRepo();
  const worktree = mkdtempSync(join(tmpdir(), "makit-repo-wt-"));
  const bin = mkdtempSync(join(tmpdir(), "makit-fake-gh-"));
  const marker = join(bin, "called");
  const prevPath = process.env.PATH;
  const prevMarker = process.env.GH_MARKER;
  try {
    rmSync(worktree, { recursive: true, force: true });
    execFileSync("git", ["worktree", "add", "-q", "-b", "feature2", worktree], { cwd });
    const gh = join(bin, "gh");
    writeFileSync(
      gh,
      '#!/bin/sh\nprintf "called\\n" >> "$GH_MARKER"\nprintf \'[{"number":7,"url":"https://x/7","state":"OPEN","title":"t","isDraft":false}]\\n\'\n',
    );
    chmodSync(gh, 0o755);
    process.env.PATH = `${bin}:${prevPath ?? ""}`;
    process.env.GH_MARKER = marker;

    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const gitOnly = await manager.listRepos({ includePrs: false });
    assert.equal(existsSync(marker), false, "git-only pass performs no PR lookup");

    const enriched = await manager.enrichPrs(gitOnly);
    const secondary = enriched[0].worktrees.find((w) => !w.isPrimary);
    assert.equal(secondary?.pr?.number, 7);
    assert.equal(existsSync(marker), true, "enrichPrs consulted gh");
    // Input snapshot is not mutated (server keeps the git-only copy around).
    assert.equal(gitOnly[0].worktrees.find((w) => !w.isPrimary)?.pr, null);
  } finally {
    if (prevPath === undefined) delete process.env.PATH;
    else process.env.PATH = prevPath;
    if (prevMarker === undefined) delete process.env.GH_MARKER;
    else process.env.GH_MARKER = prevMarker;
    execFileSync("git", ["worktree", "remove", "--force", worktree], { cwd });
    rmSync(bin, { recursive: true, force: true });
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("listRepos({ includePrs: false }) returns git-only diff numbers and skips the PR lookup", async () => {
  const cwd = makeGitRepo();
  const worktree = mkdtempSync(join(tmpdir(), "makit-repo-wt-"));
  const bin = mkdtempSync(join(tmpdir(), "makit-fake-gh-"));
  const marker = join(bin, "called");
  const prevPath = process.env.PATH;
  const prevMarker = process.env.GH_MARKER;
  try {
    rmSync(worktree, { recursive: true, force: true });
    execFileSync("git", ["worktree", "add", "-q", "-b", "feature", worktree], { cwd });
    const gh = join(bin, "gh");
    writeFileSync(gh, '#!/bin/sh\nprintf "called\\n" >> "$GH_MARKER"\nprintf "[]\\n"\n');
    chmodSync(gh, 0o755);
    process.env.PATH = `${bin}:${prevPath ?? ""}`;
    process.env.GH_MARKER = marker;

    // Uncommitted edit → insertions counted vs the default branch.
    writeFileSync(join(cwd, "README.md"), "hello\nworld\nmore\n");
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const repos = await manager.listRepos({ includePrs: false });
    const primary = repos[0].worktrees.find((w) => w.isPrimary);
    assert.ok(primary, "primary worktree listed");
    assert.equal(existsSync(marker), false, "git-only pass performs no PR lookup");
    assert.ok(primary!.insertions >= 2, `insertions ${primary!.insertions}`);

    await manager.listRepos({ includePrs: true });
    assert.equal(existsSync(marker), true, "fixture exercises the secondary worktree PR lookup");
  } finally {
    if (prevPath === undefined) delete process.env.PATH;
    else process.env.PATH = prevPath;
    if (prevMarker === undefined) delete process.env.GH_MARKER;
    else process.env.GH_MARKER = prevMarker;
    execFileSync("git", ["worktree", "remove", "--force", worktree], { cwd });
    rmSync(bin, { recursive: true, force: true });
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("promotePendingSession routes a draft-promotion failure through the session pipeline (persisted, monotonic seq)", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    // A factory whose adapter fails to start, so promotion (worktree + agent)
    // throws deterministically without touching git. Non-git project dir keeps
    // the flow in the repo dir (no worktree add).
    const mgr = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => {
        const a = stubAdapter([]);
        (a as any).start = async () => {
          throw new Error("boom");
        };
        return a;
      },
    });
    const projectId = mgr.listProjects()[0].id;
    const session = await mgr.spawnPendingSession(projectId, "pi");

    // Seed a prior durable event so the failure event must come strictly after
    // it — proving a real monotonic seq rather than the old hand-built seq:0.
    session.backfill([{ ts: 1, kind: "user.message", payload: { text: "hello" } }]);
    const priorMaxSeq = store.read(session.id).at(-1)!.seq;
    assert.ok(priorMaxSeq >= 1);

    const errs: SessionEvent[] = [];
    session.on("event", (e) => {
      if (e.kind === "session.error") errs.push(e);
    });

    const started = await mgr.promotePendingSession(session, "do a thing");
    assert.equal(started, false, "a failed promotion tells the caller not to send the turn");

    // The failure surfaced as a normal, emitted event…
    assert.equal(errs.length, 1);
    const errEvent = errs[0];
    assert.match(String((errEvent.payload as any).message), /could not create worktree/);
    // …with a real, non-zero, monotonic seq (NOT the old seq:0)…
    assert.ok(errEvent.seq > 0, `seq ${errEvent.seq} must be non-zero`);
    assert.equal(errEvent.seq, priorMaxSeq + 1, "error seq follows the prior event monotonically");

    // …that is PERSISTED and replays last, in seq order.
    const persisted = store.read(session.id);
    const seqs = persisted.map((e) => e.seq);
    assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b), "persisted events are in seq order");
    const last = persisted.at(-1)!;
    assert.equal(last.kind, "session.error");
    assert.equal(last.seq, errEvent.seq, "the persisted error carries the emitted seq");
  } finally {
    store.close();
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("archiveSession hides a session from the active list but keeps it (SPEC-29)", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-arch-"));
  try {
    const mgr = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => stubAdapter([]),
    });
    const projectId = mgr.listProjects()[0].id;
    const s = await mgr.spawnPiSession(projectId, "archive me", "pi");
    const sid = s.id;
    assert.equal(s.agentSessionId !== undefined, true);
    assert.ok(mgr.listSessions().some((d) => d.id === sid)); // active

    await mgr.archiveSession(sid);
    // Gone from the ACTIVE list, but still in the registry + resumable.
    assert.ok(!mgr.listSessions().some((d) => d.id === sid));
    // …and present in the archived list.
    assert.ok((await mgr.listArchivedSessions()).some((d) => d.id === sid && d.archived));
    const arch = mgr.getSession(sid)!;
    assert.equal(arch.archived, true);
    assert.equal(arch.agentSessionId !== undefined, true); // resume handle kept

    // Persisted archived: a fresh manager over the same store keeps it hidden.
    const mgr2 = new SessionManager({ projects: [{ id: projectId, path: cwd }], store });
    assert.equal(mgr2.getSession(sid)!.archived, true);
    assert.ok(!mgr2.listSessions().some((d) => d.id === sid));

    // Unarchive restores it to the active list.
    await mgr2.unarchiveSession(sid);
    assert.ok(mgr2.listSessions().some((d) => d.id === sid));
    assert.ok(!(await mgr2.listArchivedSessions()).some((d) => d.id === sid));
    assert.equal(mgr2.getSession(sid)!.archived, false);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    store.close();
  }
});

test('listArchivedSessions omits sessions whose project was removed (SPEC-29)', async () => {
  const cwd = mkdtempSync(join(tmpdir(), 'makit-mgr-'));
  const store = new SqliteEventStore(join(cwd, '.makit.db'));
  try {
    execFileSync('git', ['init', '-q'], { cwd });
    const mgr = new SessionManager({
      projects: [{ id: 'p1', path: cwd }],
      store,
      adapterFactory: () => stubAdapter([]),
    });
    const projectId = mgr.listProjects()[0].id;

    // Two archived sessions in the project root (not orphaned — no worktree).
    const s1 = await mgr.spawnPiSession(projectId, 's1', 'pi');
    const s2 = await mgr.spawnPiSession(projectId, 's2', 'pi');
    await mgr.archiveSession(s1.id);
    await mgr.archiveSession(s2.id);
    const archived = await mgr.listArchivedSessions();
    assert.ok(archived.some((d: SessionDTO) => d.id === s1.id && !d.orphaned));
    assert.ok(archived.some((d: SessionDTO) => d.id === s2.id && !d.orphaned));

    // Remove the project → its archived sessions are unreachable and hidden.
    mgr.removeProject(projectId);
    const after = await mgr.listArchivedSessions();
    assert.equal(after.length, 0, 'removed-project sessions are filtered out');
  } finally {
    store.close();
    rmSync(cwd, { recursive: true, force: true });
  }
});
