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
function stubAdapter(started: SpawnOpts[], calls: string[] = []): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as any).agent = "stub";
  (e as any).capabilities = { resume: true, load: false, list: true, delete: true, fork: false, archive: false, close: true };
  (e as any).agentSessionId = undefined;
  (e as any).start = async (opts: SpawnOpts) => {
    started.push(opts);
    // Adopt (or mint) a native id so the manager persists a resume handle,
    // mirroring the real adapters (SPEC-29).
    (e as any).agentSessionId = opts.resumeAgentSessionId ?? `stub-${opts.sessionId ?? "x"}`;
  };
  (e as any).send = async () => {};
  (e as any).cancel = async () => {};
  (e as any).close = async () => {
    calls.push("close");
  };
  (e as any).kill = async () => {
    calls.push("kill");
  };
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

/** Run a worktree-creation test with isolated MAKIT_WORKTREE_DIR. Cleans up automatically. */
async function withWorktreeEnv(
  fn: (opts: { manager: SessionManager; projectId: string }) => Promise<void>,
): Promise<void> {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    await fn({ manager, projectId });
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
}

test("createWorktree then renameWorktreeBranch renames the branch", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId);
    assert.ok(wt.branch);
    await manager.renameWorktreeBranch(projectId, wt.path, "renamed-branch");
    const branch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: wt.path })
      .toString()
      .trim();
    assert.equal(branch, "renamed-branch");
  });
});

test("createWorktree uses a sanitized branch name when one is supplied", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId, undefined, "My Feature!");
    assert.equal(wt.branch, "my-feature");
    const branch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: wt.path })
      .toString()
      .trim();
    assert.equal(branch, "my-feature");
  });
});

test("createWorktree keeps every word of an explicit branch name", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    // Seven words: the 6-word cap for message-derived names must not truncate
    // a name the user typed on purpose.
    const wt = await manager.createWorktree(projectId, undefined, "add user auth flow with oauth jwt");
    assert.equal(wt.branch, "add-user-auth-flow-with-oauth-jwt");
  });
});

test("createWorktree preserves slashes in the branch but flattens the directory", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId, undefined, "feat/new-ui");
    // Branch keeps its hierarchy...
    assert.equal(wt.branch, "feat/new-ui");
    const branch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: wt.path })
      .toString()
      .trim();
    assert.equal(branch, "feat/new-ui");
    // ...but the worktree directory is flattened (no nested subfolder).
    assert.equal(basename(wt.path), "feat-new-ui");
  });
});

test("createWorktree disambiguates a flattened dir that collides with an existing worktree", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    // Branch `feat-new-ui` claims dir `feat-new-ui`.
    const first = await manager.createWorktree(projectId, undefined, "feat-new-ui");
    assert.equal(first.branch, "feat-new-ui");
    assert.equal(basename(first.path), "feat-new-ui");
    // Branch `feat/new-ui` is unique as a ref but flattens to the SAME dir; the
    // dir must be disambiguated so `git worktree add` doesn't fail.
    const second = await manager.createWorktree(projectId, undefined, "feat/new-ui");
    assert.equal(second.branch, "feat/new-ui");
    assert.notEqual(basename(second.path), "feat-new-ui");
    assert.match(basename(second.path), /^feat-new-ui-\d+$/);
  });
});

test("concurrent createWorktree calls never collide (serialized per repo)", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    // Fire several creations for the SAME requested name at once. Without the
    // per-repo lock, they'd race between the uniqueness check and `git worktree
    // add` and some would throw; serialized, each gets a distinct branch + dir.
    const results = await Promise.all(
      Array.from({ length: 6 }, () => manager.createWorktree(projectId, undefined, "feat/new-ui")),
    );
    const branches = results.map((r) => r.branch);
    const dirs = results.map((r) => basename(r.path));
    assert.equal(new Set(branches).size, 6, `branches not unique: ${branches.join(", ")}`);
    assert.equal(new Set(dirs).size, 6, `dirs not unique: ${dirs.join(", ")}`);
    // First keeps the base name; the rest are suffixed.
    assert.ok(branches.includes("feat/new-ui"));
    assert.ok(dirs.includes("feat-new-ui"));
  });
});

test("createWorktree falls back to an auto name when the supplied name is blank", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId, undefined, "   ");
    assert.ok(wt.branch);
    assert.match(wt.branch as string, /^worktree-/);
  });
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

test("removeWorktree preserves closed sessions and auto-closes live ones (SPEC-29)", async () => {
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

    // Two sessions bound to the worktree: one already closed, one live.
    const draftA = await manager.spawnPendingSession(projectId, "pi", wt.path);
    await manager.promotePendingSession(draftA, "closed one");
    await manager.closeSession(draftA.id);

    const draftB = await manager.spawnPendingSession(projectId, "pi", wt.path);
    await manager.promotePendingSession(draftB, "live one");
    assert.equal(manager.getSession(draftB.id)!.closed, false);

    await manager.removeWorktree(projectId, wt.path);

    // Neither was destroyed: both survive as closed sessions.
    assert.equal(manager.getSession(draftA.id)!.closed, true); // preserved
    assert.equal(manager.getSession(draftB.id)!.closed, true); // auto-closed
    // Both are hidden from the active list.
    const active = manager.listSessions().map((d) => d.id);
    assert.ok(!active.includes(draftA.id));
    assert.ok(!active.includes(draftB.id));
    // Both appear in the closed list, flagged orphaned (worktree removed).
    const closed = await manager.listClosedSessions();
    const a = closed.find((d) => d.id === draftA.id)!;
    const b = closed.find((d) => d.id === draftB.id)!;
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

test("listRepos counts only live sessions in worktree.sessionIds (SPEC-29)", async () => {
  // The field's own protocol doc says it links the sessions bound to the worktree,
  // and closed ones are hidden from `listSessions()` and so from every
  // client-side session list — their ids resolved to nothing in the consumers that
  // map this field to rows, and SPEC-38's wrap-up brief counted them as work left
  // behind. `listRepos` is handed `allSessions()`, which keeps them.
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

    const live = await manager.spawnPendingSession(projectId, "pi", wt.path);
    await manager.promotePendingSession(live, "live one");
    const gone = await manager.spawnPendingSession(projectId, "pi", wt.path);
    await manager.promotePendingSession(gone, "closed one");
    await manager.closeSession(gone.id);

    const repos = await manager.listRepos();
    const snap = repos.find((r) => r.id === projectId)!;
    const target = snap.worktrees.find((w) => w.path === wt.path)!;
    assert.deepEqual(target.sessionIds, [live.id]);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
    store.close();
  }
});

test("reopen of an orphaned session detaches it to the repo root (SPEC-29)", async () => {
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

    const draft = await manager.spawnPendingSession(projectId, "pi", wt.path);
    await manager.promotePendingSession(draft, "orphan me");
    assert.equal(manager.getSession(draft.id)!.worktreePath !== undefined, true);

    // Deleting the worktree auto-closes the session, flagged orphaned.
    await manager.removeWorktree(projectId, wt.path);
    assert.equal((await manager.listClosedSessions()).find((d) => d.id === draft.id)!.orphaned, true);

    // Restore: it returns to the ACTIVE list, detached to the repo root — its
    // stale worktree path is cleared so it renders under the primary worktree.
    await manager.reopenSession(draft.id);
    const restored = manager.getSession(draft.id)!;
    assert.equal(restored.closed, false);
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

test("reopen of a session whose worktree is still live preserves its binding (SPEC-29)", async () => {
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

    const draft = await manager.spawnPendingSession(projectId, "pi", wt.path);
    await manager.promotePendingSession(draft, "keep me");
    const before = manager.getSession(draft.id)!;
    const boundPath = before.worktreePath;
    const boundBranch = before.branch;
    assert.ok(boundPath !== undefined, "session is bound to the worktree");

    // Close WITHOUT removing the worktree, so the recorded path stays live.
    await manager.closeSession(draft.id);
    assert.equal((await manager.listClosedSessions()).find((d) => d.id === draft.id)!.orphaned, false);

    // Restore must NOT detach: the worktree is still a live worktree, so the
    // binding is preserved (only a genuinely-absent worktree detaches to root).
    await manager.reopenSession(draft.id);
    const restored = manager.getSession(draft.id)!;
    assert.equal(restored.closed, false);
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

    const draft = await manager.spawnPendingSession(projectId, "pi", undefined, undefined, [
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

test("startPendingSession starts the agent in the bound worktree and titles it from the first message", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    // The client creates the worktree first, then spawns bound to it.
    const wt = await manager.createWorktree(projectId, undefined, "add-login-form");
    const draft = await manager.spawnPendingSession(projectId, "pi", wt.path);
    const s = await manager.startPendingSession(draft.id, "Add a login form to the app");

    assert.equal(s.pending, false);
    assert.equal(s.branch, "add-login-form");
    assert.equal(s.worktreePath, wt.path);
    assert.ok(s.worktreePath?.startsWith(realpathSync(base)), `worktree ${s.worktreePath} under ${base}`);
    assert.equal(started.length, 1, "agent should start once");
    assert.equal(started[0]?.cwd, s.worktreePath, "agent runs in the worktree");
    assert.equal(s.title, "Add a login form to the");

    const repos = await manager.listRepos();
    const listed = repos[0].worktrees.find((w) => w.branch === "add-login-form");
    assert.ok(listed, "worktree should be listed");
    assert.deepEqual(listed!.sessionIds, [s.id], "session linked to its worktree");
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
      () => manager.spawnPendingSession(projectId, "pi", "/tmp/definitely-not-a-worktree"),
      /not part of project/,
    );

    // Binding a real worktree derives the branch from git, ignoring the
    // client-supplied branch arg.
    const draft = await manager.spawnPendingSession(projectId, "pi", wt.path, "client-lied");
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
    const draft = await manager.spawnPendingSession(projectId, "pi", wt.path);
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
    const draft = await manager.spawnPendingSession(projectId, "pi", wt.path);
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

test("listRepos buckets a still-pending draft under the worktree it is bound to", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter([]) });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId);

    // A draft's worktree is known at spawn time, so it renders under that
    // worktree's row instead of needing a separate "draft" UI bucket.
    const draft = await manager.spawnPendingSession(projectId, "pi", wt.path);
    assert.equal(draft.pending, true);

    const repos = await manager.listRepos();
    const listed = repos[0].worktrees.find((w) => w.path === wt.path);
    assert.ok(listed, "the bound worktree is listed");
    assert.deepEqual(listed!.sessionIds, [draft.id], "pending draft buckets under its worktree");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("spawnPendingSession requires a worktree; without one the agent runs in the repo dir", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    // The client resolves (creating when needed) the worktree BEFORE spawning,
    // so a spawn without one no longer forks a tree on first message: it runs
    // in the repo dir (the non-git / unborn-HEAD case).
    const draft = await manager.spawnPendingSession(projectId, "pi");
    const s = await manager.startPendingSession(draft.id, "add a login form");

    assert.equal(s.worktreePath, cwd, "runs in the repo dir, no fork");
    const repos = await manager.listRepos();
    assert.equal(repos[0].worktrees.length, 1, "no extra worktree was forked");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("spawnPendingSession keeps the client's branch for the primary worktree", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    // Binding to the repo dir took the path but dropped the branch, so promotion
    // fell back to `lc.branch ?? base` and labelled the session with the
    // slugified first message instead of the branch it actually runs on.
    const draft = await manager.spawnPendingSession(projectId, "pi", cwd, "main");
    const s = await manager.startPendingSession(draft.id, "add a login form");

    assert.equal(s.worktreePath, cwd);
    assert.equal(s.branch, "main", "the branch must survive, not become a slug");
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("spawnPendingSession accepts the project's own repo dir as the worktree", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const started: SpawnOpts[] = [];
    const manager = new SessionManager({ projects: [cwd], adapterFactory: () => stubAdapter(started) });
    const projectId = manager.listProjects()[0].id;

    // `createWorktree` returns the repo dir for a non-git project / unborn HEAD,
    // so that path must be a valid spawn target rather than a "foreign path".
    const draft = await manager.spawnPendingSession(projectId, "pi", cwd);
    const s = await manager.startPendingSession(draft.id, "work here");
    assert.equal(s.worktreePath, cwd);
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
    const wt = await manager.createWorktree(projectId);
    const draft = await manager.spawnPendingSession(projectId, "pi", wt.path);

    // Two first messages fired concurrently must NOT each start an adapter —
    // they collapse onto one in-flight promotion.
    const [r1, r2] = await Promise.all([
      manager.promotePendingSession(draft, "add a login form"),
      manager.promotePendingSession(draft, "add a login form"),
    ]);

    assert.equal(r1, true);
    assert.equal(r2, true);
    assert.equal(started.length, 1, "exactly one adapter started for concurrent promotions");
    assert.equal(draft.pending, false);

    assert.equal(draft.worktreePath, wt.path, "promoted into the bound worktree");
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
    // A factory whose adapter fails to start, so promotion throws
    // deterministically without touching git. Non-git project dir keeps the
    // flow in the repo dir (no worktree add).
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
    // …naming what actually failed. Promotion does NOT create a worktree (that
    // happened at draft time), so blaming the worktree sent users chasing git.
    assert.match(String((errEvent.payload as any).message), /could not start pi: boom/);
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

/**
 * The whole point of close-over-archive: the agent-side session is released
 * GRACEFULLY (ACP `session/close` / codex `thread/unsubscribe`) and only then is
 * the process reaped. Order matters — unsubscribing a thread after SIGTERM is
 * pointless, and skipping the reap is what leaked ~1 GB of resident agents.
 */
test("closeSession closes the agent session before reaping the process (SPEC-29)", async () => {
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-close-"));
  try {
    const calls: string[] = [];
    const mgr = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => stubAdapter([], calls),
    });
    const projectId = mgr.listProjects()[0].id;
    const s = await mgr.spawnPiSession(projectId, "close me", "pi");

    await mgr.closeSession(s.id);

    assert.deepEqual(calls, ["close", "kill"], "graceful close must precede the reap");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    store.close();
  }
});

/**
 * A wedged agent must not be able to keep its memory: a close that rejects is
 * logged and the reap still happens.
 */
test("closeSession still reaps when the graceful close rejects (SPEC-29)", async () => {
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-close-fail-"));
  try {
    const calls: string[] = [];
    const mgr = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => {
        const a = stubAdapter([], calls);
        (a as any).close = async () => {
          calls.push("close");
          throw new Error("agent is wedged");
        };
        return a;
      },
    });
    const projectId = mgr.listProjects()[0].id;
    const s = await mgr.spawnPiSession(projectId, "wedged", "pi");

    await mgr.closeSession(s.id); // must not throw
    assert.deepEqual(calls, ["close", "kill"]);
    assert.equal(mgr.getSession(s.id)!.closed, true);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    store.close();
  }
});

test("closeSession hides a session from the active list but keeps it (SPEC-29)", async () => {
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
    const s = await mgr.spawnPiSession(projectId, "close me", "pi");
    const sid = s.id;
    assert.equal(s.agentSessionId !== undefined, true);
    assert.ok(mgr.listSessions().some((d) => d.id === sid)); // active

    await mgr.closeSession(sid);
    // Gone from the ACTIVE list, but still in the registry + resumable.
    assert.ok(!mgr.listSessions().some((d) => d.id === sid));
    // …and present in the closed list.
    assert.ok((await mgr.listClosedSessions()).some((d) => d.id === sid && d.closed));
    const arch = mgr.getSession(sid)!;
    assert.equal(arch.closed, true);
    assert.equal(arch.agentSessionId !== undefined, true); // resume handle kept

    // Persisted closed: a fresh manager over the same store keeps it hidden.
    const mgr2 = new SessionManager({ projects: [{ id: projectId, path: cwd }], store });
    assert.equal(mgr2.getSession(sid)!.closed, true);
    assert.ok(!mgr2.listSessions().some((d) => d.id === sid));

    // Reopen restores it to the active list.
    await mgr2.reopenSession(sid);
    assert.ok(mgr2.listSessions().some((d) => d.id === sid));
    assert.ok(!(await mgr2.listClosedSessions()).some((d) => d.id === sid));
    assert.equal(mgr2.getSession(sid)!.closed, false);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    store.close();
  }
});

test('listClosedSessions omits sessions whose project was removed (SPEC-29)', async () => {
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

    // Two closed sessions in the project root (not orphaned — no worktree).
    const s1 = await mgr.spawnPiSession(projectId, 's1', 'pi');
    const s2 = await mgr.spawnPiSession(projectId, 's2', 'pi');
    await mgr.closeSession(s1.id);
    await mgr.closeSession(s2.id);
    const closed = await mgr.listClosedSessions();
    assert.ok(closed.some((d: SessionDTO) => d.id === s1.id && !d.orphaned));
    assert.ok(closed.some((d: SessionDTO) => d.id === s2.id && !d.orphaned));

    // Remove the project → its closed sessions are unreachable and hidden.
    mgr.removeProject(projectId);
    const after = await mgr.listClosedSessions();
    assert.equal(after.length, 0, 'removed-project sessions are filtered out');
  } finally {
    store.close();
    rmSync(cwd, { recursive: true, force: true });
  }
});

// ── wrap up (PR actions) ────────────────────────────────────────────────────
// The ending a merged PR never had: remove the worktree, delete the landed
// branch, and catch the base branch up. Composes three git primitives that are
// covered in git.test.ts, so these cover the composition and the guards.

test("wrapUpWorktree removes the worktree and deletes its branch", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId);
    const branch = wt.branch as string;
    assert.ok(existsSync(wt.path));
    const repoPath = manager.listProjects()[0].path;

    const result = await manager.wrapUpWorktree(projectId, wt.path, "main");

    assert.equal(existsSync(wt.path), false, "the worktree is gone");
    assert.equal(result.branchDeleted, branch);
    const branches = execFileSync("git", ["branch", "--format=%(refname:short)"], { cwd: repoPath })
      .toString()
      .trim()
      .split("\n");
    assert.ok(!branches.includes(branch), `${branch} should be gone, got ${branches.join()}`);
  });
});

test("wrapUpWorktree reports the base branch it could not catch up", async () => {
  // The throwaway repo has no `origin`, so the sync leg cannot run. Wrap up must
  // still complete its local work and say what it skipped, rather than failing.
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId);
    const result = await manager.wrapUpWorktree(projectId, wt.path, "main");
    assert.equal(result.baseBranch, "main");
    assert.equal(result.baseUpdated, false);
    assert.ok(result.baseReason, "it must explain why the base was not updated");
  });
});

test("wrapUpWorktree refuses the repo's primary worktree", async () => {
  // Removing the primary checkout would take the repo with it.
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const repoPath = manager.listProjects()[0].path;
    await assert.rejects(
      () => manager.wrapUpWorktree(projectId, realpathSync(repoPath), "main"),
      /primary/i,
    );
  });
});

test("wrapUpWorktree refuses a path outside the project", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const stranger = mkdtempSync(join(tmpdir(), "makit-stranger-"));
    try {
      await assert.rejects(() => manager.wrapUpWorktree(projectId, stranger, "main"), /not part of/i);
    } finally {
      rmSync(stranger, { recursive: true, force: true });
    }
  });
});

test("wrapUpWorktree falls back to the repo's default branch", async () => {
  // The PR's baseRefName is the authority, but an older server (or a shed
  // lookup) may not have it. The repo's own default branch is the safe fallback.
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId);
    const result = await manager.wrapUpWorktree(projectId, wt.path);
    assert.equal(result.baseBranch, "main");
  });
});

test("wrapUpWorktree skips the branch deletion for a detached worktree", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId);
    execFileSync("git", ["checkout", "-q", "--detach"], { cwd: wt.path });
    const result = await manager.wrapUpWorktree(projectId, wt.path, "main");
    assert.equal(result.branchDeleted, undefined);
    assert.equal(existsSync(wt.path), false);
  });
});

// ── PR mutations (mark ready / update branch) ────────────────────────────────
// Both are `gh` calls routed through the gateway, so these assert the manager
// resolves the right PR for the worktree and surfaces failures rather than
// swallowing them.

/** A gateway stub that records mutatePr calls and answers prForBranch. */
function prGateway(pr: { number: number; branch: string } | null, ok = true) {
  const calls: Array<{ branch: string; number: number; verb: string }> = [];
  const lookups: Array<{ branch: string; interactive: boolean }> = [];
  const gateway = {
    async prForBranch(
      _repoPath: string,
      branch: string,
      opts?: { interactive?: boolean },
    ) {
      lookups.push({ branch, interactive: opts?.interactive === true });
      // A background lookup below SPEC-32's reserve is shed to `unknown`. Only an
      // interactive one draws on the reserve, so this stub answers accordingly.
      if (!opts?.interactive) return { kind: "unknown" as const };
      return pr && pr.branch === branch
        ? {
            kind: "pr" as const,
            pr: {
              number: pr.number,
              url: `https://github.com/o/r/pull/${pr.number}`,
              state: "OPEN",
              title: "t",
              isDraft: true,
              mergeable: "MERGEABLE",
              mergeStateStatus: "BEHIND",
              checks: [],
              checkRollup: "none" as const,
              unresolvedComments: 0,
            },
          }
        : { kind: "none" as const };
    },
    async mutatePr(_repoPath: string, branch: string, number: number, verb: string) {
      calls.push({ branch, number, verb });
      return ok ? { ok: true } : { ok: false, error: "gh said no" };
    },
    async openPrs() {
      return [];
    },
    budget: () => ({}) as never,
    history: () => [],
    refresh: async () => ({}) as never,
    setPaused: () => {},
    onBudgetChange: () => () => {},
    close: () => {},
    stats: () => ({ execs: 0, cacheHits: 0 }),
  } as unknown as import("./github/gateway.js").GithubGateway;
  return { gateway, calls, lookups };
}

test("markPrReady resolves the worktree's PR and takes it out of draft", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const { gateway, calls } = prGateway({ number: 42, branch: "feat/x" });
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: () => stubAdapter([]),
      gateway,
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "feat/x");
    await manager.markPrReady(projectId, wt.path);
    assert.deepEqual(calls, [{ branch: "feat/x", number: 42, verb: "ready" }]);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("updatePrBranch merges the base into the PR head", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const { gateway, calls } = prGateway({ number: 7, branch: "feat/y" });
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: () => stubAdapter([]),
      gateway,
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "feat/y");
    await manager.updatePrBranch(projectId, wt.path);
    assert.deepEqual(calls, [{ branch: "feat/y", number: 7, verb: "update-branch" }]);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("squashMergePr squash-merges the worktree's PR", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const { gateway, calls } = prGateway({ number: 99, branch: "feat/z" });
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: () => stubAdapter([]),
      gateway,
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "feat/z");
    await manager.squashMergePr(projectId, wt.path);
    assert.deepEqual(calls, [{ branch: "feat/z", number: 99, verb: "merge-squash" }]);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("squashMergePr leaves the worktree alone — tidying is a separate decision", async () => {
  // Merging and cleaning up are two choices. `gh pr merge --delete-branch` would
  // fold them together and pull the rug from under any session running in the
  // worktree; the merged state then advertises "Wrap up" instead.
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const { gateway } = prGateway({ number: 99, branch: "feat/z" });
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: () => stubAdapter([]),
      gateway,
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "feat/z");
    await manager.squashMergePr(projectId, wt.path);
    assert.equal(existsSync(wt.path), true);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("a PR mutation reports gh's own error rather than failing silently", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const { gateway } = prGateway({ number: 42, branch: "feat/x" }, false);
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: () => stubAdapter([]),
      gateway,
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "feat/x");
    await assert.rejects(() => manager.markPrReady(projectId, wt.path), /gh said no/);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("a PR mutation looks its PR up interactively, so a tight quota cannot hide it", async () => {
  // These three are button presses. `findOpenPr` collapses `unknown` to null, so a
  // background lookup shed below SPEC-32's reserve made "Mark ready" fail with
  // "no pull request for feat/x" — for a PR that plainly exists — exactly when the
  // account is throttled. The reserve exists for user-initiated work; drawing on
  // it is the difference between a working button and a lying error.
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const { gateway, calls, lookups } = prGateway({ number: 7, branch: "feat/x" });
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: () => stubAdapter([]),
      gateway,
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "feat/x");
    await manager.markPrReady(projectId, wt.path);
    assert.deepEqual(calls, [{ branch: "feat/x", number: 7, verb: "ready" }]);
    assert.ok(
      lookups.some((l) => l.branch === "feat/x" && l.interactive),
      "the mutation's PR lookup must be interactive",
    );
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

test("a PR mutation on a worktree with no PR is refused", async () => {
  const cwd = makeGitRepo();
  const base = mkdtempSync(join(tmpdir(), "makit-wtbase-"));
  const prevBase = process.env.MAKIT_WORKTREE_DIR;
  process.env.MAKIT_WORKTREE_DIR = base;
  try {
    const { gateway } = prGateway(null);
    const manager = new SessionManager({
      projects: [cwd],
      adapterFactory: () => stubAdapter([]),
      gateway,
    });
    const projectId = manager.listProjects()[0].id;
    const wt = await manager.createWorktree(projectId, undefined, "feat/x");
    await assert.rejects(() => manager.markPrReady(projectId, wt.path), /no pull request/i);
  } finally {
    if (prevBase === undefined) delete process.env.MAKIT_WORKTREE_DIR;
    else process.env.MAKIT_WORKTREE_DIR = prevBase;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(base, { recursive: true, force: true });
  }
});

// ── discard (SPEC-38 T7.2) ──────────────────────────────────────────────────
// A closed PR's worktree AND its branch go. Symmetry with wrap up: a verb called
// "discard" that leaves the branch behind is not discarding. The commits survive
// on origin/<branch>, since a PR cannot exist without a pushed head.

test("discardWorktree removes the worktree and deletes its branch", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId, undefined, "feat/closed");
    const repoPath = manager.listProjects()[0].path;
    assert.equal(existsSync(wt.path), true);

    await manager.discardWorktree(projectId, wt.path);

    assert.equal(existsSync(wt.path), false);
    const branches = execFileSync("git", ["branch", "--format=%(refname:short)"], { cwd: repoPath })
      .toString()
      .trim()
      .split("\n");
    assert.ok(!branches.includes("feat/closed"), `got ${branches.join()}`);
  });
});

test("discardWorktree leaves the base branch alone — nothing landed", async () => {
  // Unlike wrap up there is no merge to catch up to, so it must not touch main.
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const repoPath = manager.listProjects()[0].path;
    const before = execFileSync("git", ["rev-parse", "main"], { cwd: repoPath }).toString().trim();
    const wt = await manager.createWorktree(projectId, undefined, "feat/closed");
    await manager.discardWorktree(projectId, wt.path);
    const after = execFileSync("git", ["rev-parse", "main"], { cwd: repoPath }).toString().trim();
    assert.equal(after, before);
  });
});

test("discardWorktree refuses the repo's primary worktree", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const repoPath = manager.listProjects()[0].path;
    await assert.rejects(
      () => manager.discardWorktree(projectId, realpathSync(repoPath)),
      /primary/i,
    );
  });
});

test("discardWorktree skips the branch deletion for a detached worktree", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId, undefined, "feat/closed");
    execFileSync("git", ["checkout", "-q", "--detach"], { cwd: wt.path });
    await manager.discardWorktree(projectId, wt.path);
    assert.equal(existsSync(wt.path), false);
  });
});

test("wrap up survives a failed branch deletion and reports it", async () => {
  // The worktree is already gone by this point, so throwing would call a
  // mostly-done job a total failure — and the client could not retry, because the
  // path is no longer a registered worktree.
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId, undefined, "feat/stuck");
    const repoPath = manager.listProjects()[0].path;
    // Wedge `git branch -D`: a ref lock the delete cannot take.
    const lock = join(repoPath, ".git", "refs", "heads", "feat", "stuck.lock");
    mkdirSync(join(repoPath, ".git", "refs", "heads", "feat"), { recursive: true });
    writeFileSync(lock, "");

    const result = await manager.wrapUpWorktree(projectId, wt.path, "main");

    assert.equal(existsSync(wt.path), false, "the worktree still went");
    assert.equal(result.branchDeleted, undefined);
    assert.ok(result.branchReason, "it says why the branch survived");
  });
});

test("wrap up refuses when the worktree moved to another branch", async () => {
  // The app's confirm names a branch taken from its snapshot; the server resolves
  // the branch again at execution time. If the user checked out something else in
  // the meantime, deleting what is there now would destroy a branch the user was
  // never warned about — and `-D` is unrecoverable for unpushed work.
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId, undefined, "feat/landed");
    execFileSync("git", ["checkout", "-q", "-b", "feat/something-else"], { cwd: wt.path });

    await assert.rejects(
      () => manager.wrapUpWorktree(projectId, wt.path, "main", "feat/landed"),
      /feat\/something-else/,
    );
    assert.equal(existsSync(wt.path), true, "nothing was removed");
  });
});

test("discard refuses on a branch mismatch too", async () => {
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const wt = await manager.createWorktree(projectId, undefined, "feat/closed");
    execFileSync("git", ["checkout", "-q", "-b", "other"], { cwd: wt.path });
    await assert.rejects(
      () => manager.discardWorktree(projectId, wt.path, "feat/closed"),
      /other/,
    );
    assert.equal(existsSync(wt.path), true);
  });
});

test("a matching branch proceeds, and no expectation means no check", async () => {
  // The guard must not become a wall: an older app sends no expectation, and the
  // common case (nothing changed) has to work.
  await withWorktreeEnv(async ({ manager, projectId }) => {
    const a = await manager.createWorktree(projectId, undefined, "feat/a");
    await manager.wrapUpWorktree(projectId, a.path, "main", "feat/a");
    assert.equal(existsSync(a.path), false);

    const b = await manager.createWorktree(projectId, undefined, "feat/b");
    await manager.wrapUpWorktree(projectId, b.path, "main");
    assert.equal(existsSync(b.path), false);
  });
});

// ---------------------------------------------------------------------------
// Automatic re-attach after a server restart
// ---------------------------------------------------------------------------

/** Seed the store with a cold session as a prior server run would have left it. */
function seedColdSession(
  store: SqliteEventStore,
  id: string,
  extra: Partial<{ agentSessionId: string; resumeSessionPath: string; closed: boolean }> = {},
) {
  store.saveSession({
    id,
    projectId: "proj-x",
    agent: "pi",
    title: "prior work",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 2,
    lastPreview: "old task",
    ...extra,
  });
  store.append(id, { ts: 2, kind: "user.message", payload: { text: "old task" } });
}

/** A stub whose `start` only resolves once `release()` is called. */
function slowStubAdapter(started: SpawnOpts[]): { adapter: AgentAdapter; release: () => void } {
  let release = () => {};
  const gate = new Promise<void>((r) => {
    release = r;
  });
  const e = stubAdapter(started) as any;
  const inner = e.start;
  e.start = async (opts: SpawnOpts) => {
    await gate;
    await inner(opts);
  };
  return { adapter: e as AgentAdapter, release };
}

test("a cold session resumable only by its legacy pi path advertises resumable", () => {
  const store = new SqliteEventStore();
  seedColdSession(store, "sess-legacy", { resumeSessionPath: "/tmp/prior.jsonl" });
  const mgr = new SessionManager({ projects: [], store });
  // reattachSession accepts either handle, so the DTO must not claim otherwise —
  // a false `resumable: false` stops the client from ever offering re-attach.
  assert.equal(mgr.getSession("sess-legacy")!.toDTO().resumable, true);
  store.close();
});

test("ensureLive brings a cold resumable session back, then no-ops when it is live", async () => {
  const store = new SqliteEventStore();
  seedColdSession(store, "sess-cold", { agentSessionId: "pi-1" });
  const started: SpawnOpts[] = [];
  const mgr = new SessionManager({ projects: [], store, adapterFactory: () => stubAdapter(started) });

  await mgr.ensureLive("sess-cold");
  assert.equal(started.length, 1, "adapter started once");
  assert.equal(started[0].resumeAgentSessionId, "pi-1", "resumed by its native id");

  // Idempotent: a second subscribe must not spawn a second agent.
  await mgr.ensureLive("sess-cold");
  assert.equal(started.length, 1, "already live — no second spawn");

  // And input now reaches a live adapter instead of the cold-session error.
  const errs: string[] = [];
  mgr.getSession("sess-cold")!.on("event", (e) => {
    if (e.kind === "session.error") errs.push(String((e.payload as any).message));
  });
  await mgr.getSession("sess-cold")!.sendUserMessage("hi again");
  assert.deepEqual(errs, [], "no re-attach error after ensureLive");
  store.close();
});

test("ensureLive leaves history-only, closed, draft and unknown sessions alone", async () => {
  const store = new SqliteEventStore();
  seedColdSession(store, "sess-noresume"); // no resume handle at all
  seedColdSession(store, "sess-closed", { agentSessionId: "pi-2", closed: true });
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const started: SpawnOpts[] = [];
    const mgr = new SessionManager({ projects: [cwd], store, adapterFactory: () => stubAdapter(started) });

    // History-only: nothing to resume, so it stays read-only rather than
    // silently starting a FRESH agent that has lost the transcript.
    await mgr.ensureLive("sess-noresume");
    // Closed is a deliberate stop (SPEC-29) — resurrect only via reopen.
    await mgr.ensureLive("sess-closed");
    // A draft also holds a DetachedAdapter; it must promote, never re-attach.
    const draft = await mgr.spawnPendingSession(mgr.listProjects()[0].id);
    // Give the draft a resume handle so `pending` is the ONLY thing that can
    // stop it: without this the case passes even with the pending guard removed,
    // because a draft has no handle and `resumable` would have rejected it.
    draft.agentSessionId = "pi-draft";
    await mgr.ensureLive(draft.id);
    // An unknown id must not throw — `sub` answers no-such-session itself.
    await mgr.ensureLive("does-not-exist");

    assert.deepEqual(started, [], "no agent started for any of them");
    assert.equal(mgr.getSession("sess-noresume")!.status, "exited");
    store.close();
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("concurrent re-attach of the same cold session starts exactly one agent", async () => {
  const store = new SqliteEventStore();
  seedColdSession(store, "sess-race", { agentSessionId: "pi-3" });
  const started: SpawnOpts[] = [];
  // One slow adapter for the first call; any later call would get a second one.
  const slow = slowStubAdapter(started);
  let handedOut = 0;
  const mgr = new SessionManager({
    projects: [],
    store,
    adapterFactory: () => (handedOut++ === 0 ? slow.adapter : stubAdapter(started)),
  });

  // `sub` and a fast `send.message` (or two devices) race into re-attach.
  const all = Promise.all([
    mgr.ensureLive("sess-race"),
    mgr.ensureLive("sess-race"),
    mgr.reattachSession("sess-race"),
  ]);
  slow.release();
  await all;
  assert.equal(handedOut, 1, "one adapter built");
  assert.equal(started.length, 1, "one agent process started");
  store.close();
});

/** A stub that rejects on its first [failures] starts, then behaves normally. */
function flakyStubAdapter(started: SpawnOpts[], failures: number): AgentAdapter {
  const e = stubAdapter(started) as any;
  const inner = e.start;
  let attempts = 0;
  e.start = async (opts: SpawnOpts) => {
    if (attempts++ < failures) throw new Error("agent binary is missing");
    await inner(opts);
  };
  return e as AgentAdapter;
}

/** A stub that records how many times it was killed. */
function killTrackingAdapter(started: SpawnOpts[], kills: string[]): AgentAdapter {
  const e = stubAdapter(started) as any;
  e.kill = async () => {
    kills.push("kill");
  };
  return e as AgentAdapter;
}

test("a failed re-attach reaches every concurrent caller and does not poison the retry", async () => {
  const store = new SqliteEventStore();
  seedColdSession(store, "sess-flaky", { agentSessionId: "pi-4" });
  const started: SpawnOpts[] = [];
  const mgr = new SessionManager({
    projects: [],
    store,
    // One adapter instance across calls: it fails once, then works.
    adapterFactory: (() => {
      const shared = flakyStubAdapter(started, 1);
      return () => shared;
    })(),
  });

  const [a, b] = await Promise.allSettled([
    mgr.reattachSession("sess-flaky"),
    mgr.reattachSession("sess-flaky"),
  ]);
  assert.equal(a.status, "rejected");
  assert.equal(b.status, "rejected", "the second caller sees the same failure, not a hang");
  assert.match(String((a as PromiseRejectedResult).reason.message), /agent binary is missing/);
  assert.deepEqual(started, [], "nothing started");

  // The in-flight entry must be gone, or the session could never be resumed
  // again for the lifetime of the server.
  const live = await mgr.reattachSession("sess-flaky");
  assert.equal(live.id, "sess-flaky");
  assert.equal(started.length, 1, "the retry really started an agent");
  store.close();
});

test("a failed re-attach leaves the session cold, so the next attempt retries it", async () => {
  const store = new SqliteEventStore();
  seedColdSession(store, "sess-failstart", { agentSessionId: "pi-5" });
  const started: SpawnOpts[] = [];
  const mgr = new SessionManager({
    projects: [],
    store,
    adapterFactory: (() => {
      const shared = flakyStubAdapter(started, 1);
      return () => shared;
    })(),
  });

  // ensureLive swallows the failure — `sub` must still replay the transcript.
  await assert.doesNotReject(() => mgr.ensureLive("sess-failstart"));
  assert.deepEqual(started, [], "no agent started");

  // And the session must be COLD again, not stuck holding a dead adapter:
  // input still gets the actionable re-attach error...
  const session = mgr.getSession("sess-failstart")!;
  const errs: string[] = [];
  session.on("event", (e) => {
    if (e.kind === "session.error") errs.push(String((e.payload as any).message));
  });
  await session.sendUserMessage("hi");
  assert.match(errs[0] ?? "", /re-attach/, "still reports itself cold");

  // ...and the NEXT subscribe retries instead of giving up forever.
  await mgr.ensureLive("sess-failstart");
  assert.equal(started.length, 1, "retried and came back live");
  store.close();
});

test("re-attaching a live session stops the outgoing agent instead of orphaning it", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const started: SpawnOpts[] = [];
    const kills: string[] = [];
    const mgr = new SessionManager({
      projects: [cwd],
      adapterFactory: () => killTrackingAdapter(started, kills),
    });
    await mgr.ensureDefaultSessions();
    const session = mgr.allSessions()[0]!;
    const outgoing = session.adapter;
    assert.equal(started.length, 1);

    // An explicit `session.attach` on a session that is already live (e.g. a
    // second device acted on a stale snapshot). The old process must be stopped
    // — replacing the adapter alone would leave it running, unreachable.
    await mgr.reattachSession(session.id);
    assert.equal(kills.length, 1, "the outgoing agent was killed");
    assert.notEqual(session.adapter, outgoing, "and swapped out");
    assert.equal(started.length, 2, "the resumed agent started");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

test("a replaced adapter can no longer feed the session it was swapped out of", async () => {
  const cwd = mkdtempSync(join(tmpdir(), "makit-proj-"));
  try {
    const started: SpawnOpts[] = [];
    const mgr = new SessionManager({
      projects: [cwd],
      adapterFactory: () => {
        const a = stubAdapter(started) as any;
        a.steer = async () => false; // can't steer -> the message queues
        return a as AgentAdapter;
      },
    });
    await mgr.ensureDefaultSessions();
    const session = mgr.allSessions()[0]!;
    const outgoing = session.adapter;
    // Busy + unsteerable, so the message lands in the pending queue (SPEC-35).
    outgoing.emit("status", "running");
    await session.sendUserMessage("queued while running");
    assert.equal(session.queuedMessages.length, 1, "precondition: one queued message");
    const before = session.events.length;

    await mgr.reattachSession(session.id);

    // A late event from the dead adapter must not land in the transcript, and
    // its exit must not wipe the queue the resumed agent is about to flush.
    outgoing.emit("event", { ts: Date.now(), kind: "user.message", payload: { text: "ghost" } });
    outgoing.emit("exit", null);
    assert.equal(
      session.events.some((e) => (e.payload as any)?.text === "ghost"),
      false,
      "no ghost event from the replaced adapter",
    );
    assert.equal(session.events.length >= before, true);
    assert.equal(session.queuedMessages.length, 1, "queue survived the re-attach");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// SPEC-29 — idle auto-close (option D). makit runs one agent process per
// session and nothing ever took an idle one down, so agents accumulated until
// the daemon died: measured 19 resident agents / ~0.95 GB RSS, some 3–5 days
// old. The sweeper closes sessions nobody is working with, and because close
// keeps the transcript + resume handle it is always reversible.
// ---------------------------------------------------------------------------

/** A manager with the idle sweeper armed, plus a live (non-draft) session. */
async function idleFixture(opts: { idleCloseMs?: number } = {}) {
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-idle-"));
  const calls: string[] = [];
  const mgr = new SessionManager({
    projects: [cwd],
    store,
    adapterFactory: () => stubAdapter([], calls),
    idleCloseMs: opts.idleCloseMs ?? 60_000,
  });
  const projectId = mgr.listProjects()[0].id;
  const session = await mgr.spawnPiSession(projectId, "idle-victim", "pi");
  return {
    mgr,
    session,
    calls,
    cleanup: () => {
      rmSync(cwd, { recursive: true, force: true });
      store.close();
    },
  };
}

test("sweepIdleSessions closes a session idle past the threshold, reversibly", async () => {
  const { mgr, session, calls, cleanup } = await idleFixture();
  try {
    const now = Date.now();
    session.lastActivityAt = now - 120_000; // 2 min idle, threshold 1 min
    session.status = "idle";

    const closedIds = await mgr.sweepIdleSessions(now);

    assert.deepEqual(closedIds, [session.id]);
    assert.equal(session.closed, true);
    assert.deepEqual(calls, ["close", "kill"], "released gracefully, then reaped");
    // Reversible: the record + resume handle survive, so reopen resumes.
    const row = (await mgr.listClosedSessions()).find((d) => d.id === session.id);
    assert.ok(row, "must appear in the closed list");
    assert.equal(session.resumable, true, "resume handle kept");
  } finally {
    cleanup();
  }
});

test("sweepIdleSessions leaves a recently-active session alone", async () => {
  const { mgr, session, cleanup } = await idleFixture();
  try {
    const now = Date.now();
    session.lastActivityAt = now - 5_000; // well inside the threshold
    session.status = "idle";

    assert.deepEqual(await mgr.sweepIdleSessions(now), []);
    assert.equal(session.closed, false);
  } finally {
    cleanup();
  }
});

/**
 * The guards that make auto-close safe. Each of these would destroy work or
 * free nothing, so an idle timestamp alone must never be enough.
 */
test("sweepIdleSessions never closes a session that is mid-turn or waiting on the user", async () => {
  for (const status of ["running", "awaiting-input", "awaiting-approval"] as const) {
    const { mgr, session, cleanup } = await idleFixture();
    try {
      session.lastActivityAt = Date.now() - 10 * 60_000;
      session.status = status;

      assert.deepEqual(await mgr.sweepIdleSessions(Date.now()), [], `must skip ${status}`);
      assert.equal(session.closed, false, `must skip ${status}`);
    } finally {
      cleanup();
    }
  }
});

test("sweepIdleSessions skips drafts and already-cold sessions (nothing to free)", async () => {
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-idle-skip-"));
  try {
    const mgr = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => stubAdapter([]),
      idleCloseMs: 60_000,
    });
    const projectId = mgr.listProjects()[0].id;
    // A never-promoted draft: no agent process exists, and closing it would
    // persist an empty row in the Closed list.
    const draft = await mgr.spawnPendingSession(projectId);
    draft.lastActivityAt = Date.now() - 10 * 60_000;

    assert.deepEqual(await mgr.sweepIdleSessions(Date.now()), []);
    assert.equal(draft.closed, false);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    store.close();
  }
});

/**
 * Auto-close must never cost the user the ability to continue. A session with no
 * native resume handle cannot be brought back, so it is held rather than freed
 * (the user can still close it by hand).
 */
test("sweepIdleSessions refuses to auto-close a non-resumable session", async () => {
  const { mgr, session, cleanup } = await idleFixture();
  try {
    session.lastActivityAt = Date.now() - 10 * 60_000;
    session.status = "idle";
    // Strip the resume handle: the adapter minted one on start.
    (session as unknown as { _agentSessionId?: string })._agentSessionId = undefined;
    Object.defineProperty(session, "resumable", { get: () => false, configurable: true });

    assert.deepEqual(await mgr.sweepIdleSessions(Date.now()), []);
    assert.equal(session.closed, false);
  } finally {
    cleanup();
  }
});

test("idleCloseMs = 0 disables the sweeper entirely", async () => {
  const { mgr, session, cleanup } = await idleFixture({ idleCloseMs: 0 });
  try {
    session.lastActivityAt = Date.now() - 24 * 60 * 60_000; // a day idle
    session.status = "idle";

    assert.deepEqual(await mgr.sweepIdleSessions(Date.now()), []);
    assert.equal(session.closed, false);
  } finally {
    cleanup();
  }
});

/**
 * Recovery has to be invisible, or auto-close is just a way to lose your place:
 * sending a message to a closed session reopens and resumes it. Subscribing does
 * NOT (viewing a transcript must never respawn an agent).
 */
test("ensureLiveForInput reopens a closed session; ensureLive alone does not", async () => {
  const { mgr, session, cleanup } = await idleFixture();
  try {
    session.lastActivityAt = Date.now() - 120_000;
    session.status = "idle";
    await mgr.sweepIdleSessions(Date.now());
    assert.equal(session.closed, true);

    // Viewing: stays closed, replays read-only.
    await mgr.ensureLive(session.id);
    assert.equal(session.closed, true, "sub must not respawn an agent");

    // Sending: unambiguous intent to continue → reopened.
    await mgr.ensureLiveForInput(session.id);
    assert.equal(session.closed, false, "a message must transparently reopen");
  } finally {
    cleanup();
  }
});

test("startIdleSweeper arms the injected timer and stopIdleSweeper clears it", async () => {
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-idle-timer-"));
  try {
    let armed: { ms: number } | undefined;
    let cleared = false;
    const mgr = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => stubAdapter([]),
      idleCloseMs: 60_000,
      idleSweepMs: 5_000,
      setTimer: (_fn, ms) => {
        armed = { ms };
        return "h";
      },
      clearTimer: () => {
        cleared = true;
      },
    });

    mgr.startIdleSweeper();
    assert.deepEqual(armed, { ms: 5_000 });
    mgr.stopIdleSweeper();
    assert.equal(cleared, true);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    store.close();
  }
});

/**
 * The guards must be re-checked immediately before each close, not once when the
 * victim list is built. A sweep is SLOW — every close awaits an agent round-trip
 * plus up to the SIGTERM grace period — so with several sessions the window is
 * tens of seconds. A message arriving in that window flips a later victim to
 * `running`; closing it anyway would tear the agent out from under a live turn,
 * which is exactly the data loss the guards exist to prevent.
 */
test("sweepIdleSessions re-checks each victim after the awaits (no close mid-turn)", async () => {
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-idle-race-"));
  try {
    const bySession = new Map<string, any>();
    const mgr = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: (ctx) => {
        const a: any = stubAdapter([]);
        bySession.set(ctx.sessionId!, a);
        return a;
      },
      idleCloseMs: 60_000,
    });
    const projectId = mgr.listProjects()[0].id;
    const first = await mgr.spawnPiSession(projectId, "closes-slowly", "pi");
    const second = await mgr.spawnPiSession(projectId, "gets-a-message", "pi");

    const idle = Date.now() - 10 * 60_000;
    for (const s of [first, second]) {
      s.lastActivityAt = idle;
      s.status = "idle";
    }

    // While the FIRST session is being closed, a user message lands on the
    // second: its turn starts and its activity refreshes.
    bySession.get(first.id).close = async () => {
      second.status = "running";
      second.lastActivityAt = Date.now();
    };

    const closed = await mgr.sweepIdleSessions(Date.now());

    assert.deepEqual(closed, [first.id], "only the genuinely idle session may be closed");
    assert.equal(second.closed, false, "must not close a session that started a turn mid-sweep");
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    store.close();
  }
});

/**
 * Contract enforcement, not politeness: `AgentAdapter.close()` must never throw
 * AND never hang. The manager cannot trust an implementation to honour that, and
 * the consequence of a hang is severe — `kill()` is never reached (the RSS this
 * branch exists to reclaim stays held) and `sweeping` never clears, so the idle
 * sweeper is disabled for the lifetime of the daemon.
 */
test("closeSession reaps even when the agent's close() never settles", async () => {
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-close-hang-"));
  try {
    const calls: string[] = [];
    const mgr = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => {
        const a: any = stubAdapter([], calls);
        a.close = () => {
          calls.push("close");
          return new Promise<void>(() => {}); // hangs forever
        };
        return a;
      },
      idleCloseMs: 60_000,
      closeGraceMs: 30,
    });
    const projectId = mgr.listProjects()[0].id;
    const s = await mgr.spawnPiSession(projectId, "hung-agent", "pi");

    const started = Date.now();
    await mgr.closeSession(s.id);

    assert.ok(Date.now() - started < 2000, "must not block on a hung close()");
    assert.deepEqual(calls, ["close", "kill"], "the reap must still happen");
    assert.equal(s.closed, true);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    store.close();
  }
});

test("a hung close does not wedge the sweeper for later sessions", async () => {
  const store = new SqliteEventStore();
  const cwd = mkdtempSync(join(tmpdir(), "makit-close-hang-sweep-"));
  try {
    const mgr = new SessionManager({
      projects: [cwd],
      store,
      adapterFactory: () => {
        const a: any = stubAdapter([]);
        a.close = () => new Promise<void>(() => {});
        return a;
      },
      idleCloseMs: 60_000,
      closeGraceMs: 20,
    });
    const projectId = mgr.listProjects()[0].id;
    const first = await mgr.spawnPiSession(projectId, "hangs", "pi");
    first.lastActivityAt = Date.now() - 10 * 60_000;
    first.status = "idle";
    assert.deepEqual(await mgr.sweepIdleSessions(Date.now()), [first.id]);

    // A later sweep must still work — `sweeping` cannot be left stuck true.
    const second = await mgr.spawnPiSession(projectId, "also-idle", "pi");
    second.lastActivityAt = Date.now() - 10 * 60_000;
    second.status = "idle";
    assert.deepEqual(await mgr.sweepIdleSessions(Date.now()), [second.id]);
  } finally {
    rmSync(cwd, { recursive: true, force: true });
    store.close();
  }
});

/**
 * Nested deadlines only work if the inner one is strictly tighter. The ACP
 * adapter bounds its own `session/close`, and the manager bounds
 * `adapter.close()` as a backstop for adapters it cannot trust. If the adapter's
 * bound were the looser of the two it could never fire on the normal
 * `closeSession` path: the manager would abandon the call first, leaving the
 * adapter's timer pending against a transport `kill()` had already disposed —
 * defence in depth that only looks layered.
 *
 * Asserted rather than commented so a future tweak to either constant cannot
 * silently invert the ordering.
 */
test("the adapter's own close deadline is tighter than the manager's backstop", async () => {
  const { ACP_CLOSE_TIMEOUT } = await import("./adapters/acp.js");
  const { DEFAULT_CLOSE_GRACE_MS } = await import("./manager.js");
  assert.ok(
    ACP_CLOSE_TIMEOUT < DEFAULT_CLOSE_GRACE_MS,
    `adapter close deadline (${ACP_CLOSE_TIMEOUT}ms) must be < the manager backstop (${DEFAULT_CLOSE_GRACE_MS}ms)`,
  );
});
