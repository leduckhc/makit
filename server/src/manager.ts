/**
 * SessionManager: owns projects & sessions. M0 is hardcoded to one
 * project (the server's cwd, or one passed via --project) with one
 * default pi session — enough to validate end-to-end.
 *
 * Multi-project / multi-session arrives with the home-screen FAB in M3.
 */

import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { basename, resolve } from "node:path";
import type { AgentAdapter } from "./adapters/adapter.js";
import type { AskUser } from "./uicall.js";
import { listAgents, type AgentDescriptor } from "./adapters/catalog.js";
import { Session } from "./session.js";
import { DEFAULT_SESSION_TITLE, type ProjectDTO, type RepoDTO } from "./protocol.js";
import { listPiSessions, parseTranscript, type PiSessionMeta } from "./pi-sessions.js";
import { DetachedAdapter } from "./adapters/detached.js";
import { buildAdapter } from "./agent_factory.js";
import { listRepos, enrichPrs } from "./repo_service.js";
import {
  isGitRepo,
  detectDefaultBranch,
  listWorktrees,
  addWorktree,
  addWorktreeForPr,
  removeWorktree,
  renameBranch,
  listOpenPrs,
  findOpenPr,
  branchExists,
  slugify,
  type OpenPr,
} from "./git.js";
import type { EventStore } from "./storage/event_store.js";
import { log } from "./log.js";

export interface AdapterFactoryContext {
  projectPath: string;
  sessionId: string;
  /** Resolved agent id for this session (e.g. "pi", "codex"). */
  agent: string;
}

export type AdapterFactory = (context: AdapterFactoryContext) => AgentAdapter;

export interface ManagerOpts {
  /** Project roots to expose. */
  projects: string[];
  /** Override the production pi adapter, used by deterministic e2e tests. */
  adapterFactory?: AdapterFactory;
  /**
   * Called with the current list of project paths after every add/remove so
   * the caller can persist them. Injected to keep the manager fs-agnostic.
   */
  onProjectsChanged?: (paths: string[]) => void;
  /**
   * Force every spawned pi session onto a specific model (`--model`). Used by
   * the real-pi e2e to select the fake model provider. Unset in production, so
   * pi uses its own configured default.
   */
  defaultModel?: string;
  /**
   * Durable event log. When present, spawned sessions persist their events +
   * metadata, and any sessions already in the store are rehydrated on boot as
   * read-only history so clients can resume after a server restart.
   */
  store?: EventStore;
}

export interface BridgeBinding {
  url: string;
  token: string;
  /** Absolute paths to connector `.ts` files (loaded via `pi -e`). */
  extensionPaths: string[];
  /**
   * Present a UICall on the phone and resolve with the answer. Used by the
   * PiAdapter UI interceptor to transport pi's ctx.ui.* calls to the app.
   */
  askUser?: AskUser;
}

interface ProjectEntry {
  dto: ProjectDTO;
}

export class SessionManager extends EventEmitter {
  private readonly projects = new Map<string, ProjectEntry>();
  private readonly sessions = new Map<string, Session>();
  /** pi session uuid → live makit session id, so re-attach reuses the process. */
  private readonly attachedByPi = new Map<string, string>();
  /** In-flight attaches, so concurrent attach calls collapse onto one process. */
  private readonly attachInFlight = new Map<string, Promise<Session>>();
  /** In-flight draft promotions, keyed by session id, so concurrent first
   *  messages collapse onto one worktree/adapter instead of racing. */
  private readonly promoteInFlight = new Map<string, Promise<boolean>>();
  /** Materialized shared worktrees, keyed by virtual-worktree id. Populated by
   *  the first draft in a split group to send a message; siblings reuse it. */
  private readonly virtualWorktrees = new Map<string, { path: string; branch: string }>();
  /** In-flight virtual-worktree materializations, keyed by virtual-worktree id,
   *  so two sibling drafts racing to send first fork ONE tree, not two. */
  private readonly vwInFlight = new Map<string, Promise<{ path: string; branch: string }>>();
  private readonly adapterFactory?: AdapterFactory;
  private readonly onProjectsChanged?: (paths: string[]) => void;
  private readonly defaultModel?: string;
  private readonly defaultAgentId: string;
  private readonly store?: EventStore;
  private bridge?: BridgeBinding;

  constructor(opts: ManagerOpts) {
    super();
    this.adapterFactory = opts.adapterFactory;
    this.onProjectsChanged = opts.onProjectsChanged;
    this.defaultModel = opts.defaultModel;
    this.defaultAgentId = "pi";
    this.store = opts.store;
    for (const path of opts.projects) {
      const id = randomUUID();
      this.projects.set(id, {
        dto: {
          id,
          name: basename(path),
          path,
          pinned: true,
          lastActivityAt: Date.now(),
        },
      });
    }
    this.rehydrate();
  }

  /**
   * Rebuild persisted sessions from the store as cold, read-only history so a
   * reconnecting client sees prior transcripts after a server restart. Cold
   * sessions use {@link DetachedAdapter} (no process); sending input to one
   * emits a `session.error` until it is re-attached. No-op without a store.
   *
   * Only session METADATA is loaded here — each session's event history is
   * read lazily on first access (see {@link SessionInit.hydrateFrom}), so boot
   * stays fast and memory stays proportional to the sessions actually opened,
   * not the total size of the event log.
   */
  private rehydrate(): void {
    const store = this.store;
    if (!store) return;
    for (const meta of store.loadSessions()) {
      const session = new Session({
        id: meta.id,
        projectId: meta.projectId,
        agent: meta.agent,
        title: meta.title,
        policy: meta.policy,
        adapter: new DetachedAdapter(meta.agent),
        store,
        createdAt: meta.createdAt,
        status: "exited",
        lastActivityAt: meta.lastActivityAt,
        lastPreview: meta.lastPreview,
        resumeSessionPath: meta.resumeSessionPath,
        hydrateFrom: () => store.read(meta.id),
      });
      this.sessions.set(session.id, session);
    }
    if (this.sessions.size > 0) {
      log.info(`[makit] rehydrated ${this.sessions.size} session(s) from the event log`);
    }
  }

  /** Listing for the home screen. */
  listProjects(): ProjectDTO[] {
    return [...this.projects.values()].map((p) => p.dto);
  }

  /**
   * Add a project by path. Resolves + dedupes by resolved path: if an existing
   * project already points at the same directory its DTO is returned unchanged
   * (no persist hook fired). Otherwise a new unpinned project is created and
   * the persist hook is notified.
   */
  addProject(path: string): ProjectDTO {
    const resolved = resolve(path);
    const existing = [...this.projects.values()].find(
      (p) => resolve(p.dto.path) === resolved,
    );
    if (existing) return existing.dto;

    const id = randomUUID();
    const dto: ProjectDTO = {
      id,
      name: basename(resolved),
      path: resolved,
      pinned: false,
      lastActivityAt: Date.now(),
    };
    this.projects.set(id, { dto });
    this.notifyProjectsChanged();
    return dto;
  }

  /** Remove a project by id. Throws on an unknown id. Sessions are left as-is. */
  removeProject(id: string): void {
    if (!this.projects.has(id)) throw new Error(`unknown project: ${id}`);
    this.projects.delete(id);
    this.notifyProjectsChanged();
  }

  private notifyProjectsChanged(): void {
    this.onProjectsChanged?.([...this.projects.values()].map((p) => p.dto.path));
  }

  listSessions() {
    return [...this.sessions.values()].map((s) => s.toDTO());
  }

  getSession(id: string): Session | undefined {
    return this.sessions.get(id);
  }

  /** Set the loopback bridge + askUser wiring so subsequently-spawned pi
   *  sessions can transport `ctx.ui.*` calls to the app (PiAdapter interceptor). */
  setBridge(bridge: BridgeBinding) {
    this.bridge = bridge;
  }

  /** Spawn a fresh pi session inside `projectId`. */
  async spawnPiSession(projectId: string, title?: string, agent?: string): Promise<Session> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    return this.createSession(project, { title, agent });
  }

  /** Agents this host can offer for selection in the app. */
  listAgents(): AgentDescriptor[] {
    return listAgents();
  }

  /**
   * Spawn a session for a chosen agent. Native pi keeps the multiplexer-pane
   * path (World B/D mirror); ACP-backed agents always run
   * headless since there's no real TUI to mirror.
   */
  async spawnSession(projectId: string, title?: string, agent?: string): Promise<Session> {
    const agentId = agent ?? this.defaultAgentId;
    return this.spawnPiSession(projectId, title, agentId);
  }

  /**
   * Spawn a DRAFT session: no worktree, no agent process. Worktree + agent
   * creation is deferred until the first substantive user message (see
   * {@link startPendingSession}), which supplies the branch/worktree name.
   * Uses a {@link DetachedAdapter} placeholder so the session wires + shows in
   * snapshots immediately.
   */
  async spawnPendingSession(projectId: string, agent?: string, baseBranch?: string, worktreePath?: string, branch?: string): Promise<Session> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    const agentId = agent ?? this.defaultAgentId;
    const session = new Session({
      projectId: project.dto.id,
      agent: this.adapterFactory ? "stub" : agentId,
      title: DEFAULT_SESSION_TITLE,
      adapter: new DetachedAdapter(agentId),
      store: this.store,
    });
    session.beginDraft({ agent: agentId, baseBranch });
    // Bind to an existing worktree when provided (start-a-session-in-worktree):
    // first message launches the agent there instead of forking a new tree.
    // The path comes from the wire, so verify it is genuinely a worktree of
    // this project and derive the branch from git rather than trusting the
    // client — otherwise a client could launch an agent outside the project.
    if (worktreePath) {
      const entries = await listWorktrees(project.dto.path);
      const match = entries.find(
        (e) => resolve(e.path) === resolve(worktreePath),
      );
      if (!match) {
        throw new Error(
          `worktree is not part of project ${projectId}: ${worktreePath}`,
        );
      }
      session.beginDraft({
        agent: agentId,
        baseBranch,
        pendingWorktreePath: match.path,
        branch: match.branch ?? branch,
      });
    }
    this.sessions.set(session.id, session);
    this.emit("sessionCreated", session);
    return session;
  }

  /**
   * Spawn a new session that shares the SAME worktree as [sourceSessionId]
   * (the split-pane flow). Mirrors the source's worktree regardless of whether
   * it exists yet:
   * - source already started → bind the new draft to its real worktree/branch
   *   (first message launches the agent there, no new tree).
   * - source still a draft → link both drafts to one virtual worktree so
   *   whichever sends first forks it and the other reuses that tree.
   */
  async spawnLinkedSession(sourceSessionId: string): Promise<Session> {
    const source = this.sessions.get(sourceSessionId);
    if (!source) throw new Error(`no such session: ${sourceSessionId}`);
    const lc = source.lifecycle;
    const agent = source.pendingAgent ?? source.agent;
    if (lc.phase === "started") {
      // Real worktree already on disk — reuse it via the existing bind path.
      const worktreePath = lc.worktreePath;
      if (!worktreePath) {
        throw new Error(`session ${sourceSessionId} has no worktree to share`);
      }
      return this.spawnPendingSession(source.projectId, agent, undefined, worktreePath, lc.branch);
    }
    // Draft source: ensure it carries a virtual-worktree id, then hand the same
    // id to the new draft so both materialize into one tree.
    let virtualWorktreeId = lc.virtualWorktreeId;
    if (!virtualWorktreeId) {
      virtualWorktreeId = randomUUID();
      source.linkVirtualWorktree(virtualWorktreeId);
    }
    const session = new Session({
      projectId: source.projectId,
      agent: this.adapterFactory ? "stub" : agent,
      title: DEFAULT_SESSION_TITLE,
      adapter: new DetachedAdapter(agent),
      store: this.store,
    });
    session.beginDraft({ agent, baseBranch: lc.baseBranch, virtualWorktreeId });
    this.sessions.set(session.id, session);
    this.emit("sessionCreated", session);
    return session;
  }

  /**
   * Change the harness a still-pending draft will start with. No-op once the
   * session has been promoted (its agent process already exists).
   */
  setPendingAgent(sessionId: string, agent: string): Session {
    const session = this.sessions.get(sessionId);
    if (!session) throw new Error(`no such session: ${sessionId}`);
    if (session.pending) session.setPendingAgent(agent);
    return session;
  }

  /**
   * Create a fresh worktree off `baseBranch` (default branch when unset) with
   * an auto-generated branch name, WITHOUT a session (the + New worktree flow).
   * The worktree exists immediately; the session is started later once the
   * user picks a harness and sends the first message (see spawnPendingSession
   * with a bound worktreePath). For a non-git project, returns the repo dir.
   */
  async createWorktree(
    projectId: string,
    baseBranch?: string,
  ): Promise<{ path: string; branch: string | null }> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    const repoPath = project.dto.path;
    if (!(await isGitRepo(repoPath))) return { path: repoPath, branch: null };
    const base =
      baseBranch && (await branchExists(repoPath, baseBranch))
        ? baseBranch
        : await detectDefaultBranch(repoPath);
    // Unborn HEAD (no commits yet): `git worktree add -b` would fail, so run
    // the session in the repo dir instead of forking a worktree.
    if (!base) return { path: repoPath, branch: null };
    const branch = await this.uniqueBranch(
      repoPath,
      `worktree-${randomUUID().slice(0, 6)}`,
    );
    const path = await addWorktree({
      repoPath,
      name: branch,
      branch,
      baseBranch: base,
    });
    return { path, branch };
  }

  /** Open PRs for a project, for the "New worktree from PR" picker. */
  async listOpenPrs(projectId: string): Promise<OpenPr[]> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    return listOpenPrs(project.dto.path);
  }

  /**
   * Create a worktree that checks out the given PR's head branch. Throws if the
   * project is unknown/non-git or the checkout fails.
   */
  async createWorktreeFromPr(
    projectId: string,
    prNumber: number,
  ): Promise<{ path: string; branch: string }> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    const repoPath = project.dto.path;
    if (!(await isGitRepo(repoPath))) throw new Error(`not a git repo: ${repoPath}`);
    const prs = await listOpenPrs(repoPath);
    const pr = prs.find((p) => p.number === prNumber);
    if (!pr) throw new Error(`PR #${prNumber} is not an open PR of this repo`);
    return addWorktreeForPr({ repoPath, prNumber, headRefName: pr.headRefName });
  }

  /**
   * Rename a worktree's checked-out branch. Refuses when the branch has an
   * open PR (renaming locally would diverge from the PR's remote head).
   */
  async renameWorktreeBranch(
    projectId: string,
    worktreePath: string,
    newName: string,
  ): Promise<void> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    const repoPath = project.dto.path;
    const trees = await listWorktrees(repoPath);
    const wt = trees.find((t) => resolve(t.path) === resolve(worktreePath));
    if (!wt) throw new Error(`worktree is not part of project ${projectId}: ${worktreePath}`);
    const oldName = wt.branch;
    if (!oldName) throw new Error(`worktree has no branch to rename: ${worktreePath}`);
    if (wt.isPrimary) {
      throw new Error(`cannot rename the primary worktree's branch: ${oldName}`);
    }
    if (await findOpenPr(repoPath, oldName)) {
      throw new Error(`cannot rename ${oldName}: it has an open pull request`);
    }
    await renameBranch(worktreePath, oldName, newName);
  }

  /**
   * Remove a worktree. Validates the path belongs to the project and is not the
   * primary checkout *before* touching anything, then kills any sessions bound
   * to it and runs `git worktree remove --force` (so a dirty tree still
   * deletes). Throws if validation or the git removal fails.
   */
  async removeWorktree(projectId: string, worktreePath: string): Promise<void> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    const repoPath = project.dto.path;
    const target = resolve(worktreePath);
    const trees = await listWorktrees(repoPath);
    const wt = trees.find((t) => resolve(t.path) === target);
    if (!wt) throw new Error(`worktree is not part of project ${projectId}: ${worktreePath}`);
    if (wt.isPrimary) throw new Error(`cannot remove the repo's primary worktree: ${worktreePath}`);
    // Validated: only now is it safe to kill sessions (destructive) before the
    // git removal.
    for (const session of this.sessions.values()) {
      if (
        session.projectId === projectId &&
        session.worktreePath &&
        resolve(session.worktreePath) === target
      ) {
        await this.killSession(session.id);
      }
    }
    await removeWorktree(repoPath, worktreePath, true);
  }

  /**
   * Promote a pending session on its first real request: derive a branch +
   * worktree name from `firstMessage`, create the worktree under
   * `MAKIT_WORKTREE_DIR` off the repo's default branch, then start the chosen
   * agent there. Idempotent — a non-pending session is returned unchanged. For
   * a non-git project the agent runs in the repo dir (no worktree).
   */
  async startPendingSession(sessionId: string, firstMessage: string): Promise<Session> {
    const session = this.sessions.get(sessionId);
    if (!session) throw new Error(`no such session: ${sessionId}`);
    const lc = session.lifecycle;
    if (lc.phase !== "draft") return session;

    const project = this.projects.get(session.projectId);
    if (!project) throw new Error(`unknown project: ${session.projectId}`);
    const repoPath = project.dto.path;
    const agentId = lc.agent;
    // Preserve the harness the user actually chose: markStarted() clears
    // pendingAgent, so pin the authoritative agent field here (unless the
    // stub adapter factory is driving tests).
    if (!this.adapterFactory) session.agent = agentId;

    const base = slugify(firstMessage) || `session-${session.id.slice(0, 8)}`;
    let branch = base;
    let worktreePath = repoPath;

    if (lc.pendingWorktreePath) {
      // Start in the existing worktree the user picked — no new tree/branch.
      worktreePath = lc.pendingWorktreePath;
      branch = lc.branch ?? base;
    } else if (lc.virtualWorktreeId) {
      // Shared virtual worktree (split-from-draft): the first sibling to reach
      // here forks the tree and records it; the rest reuse the same one.
      const shared = await this.materializeVirtualWorktree(
        lc.virtualWorktreeId,
        repoPath,
        lc.baseBranch,
        base,
      );
      worktreePath = shared.path;
      branch = shared.branch;
    } else if (await isGitRepo(repoPath)) {
      const requested = lc.baseBranch;
      const baseBranch =
        requested && (await branchExists(repoPath, requested))
          ? requested
          : await detectDefaultBranch(repoPath);
      // Unborn HEAD (no base commit): skip worktree creation, run in the repo
      // dir — `git worktree add -b` would otherwise fail.
      if (baseBranch) {
        branch = await this.uniqueBranch(repoPath, base);
        worktreePath = await addWorktree({ repoPath, name: branch, branch, baseBranch });
      }
    }

    const built = buildAdapter(agentId);
    const adapter =
      this.adapterFactory?.({ projectPath: worktreePath, sessionId: session.id, agent: agentId }) ??
      built.adapter;
    session.replaceAdapter(adapter);
    await adapter.start(this.startOpts(worktreePath, session.id));
    session.markStarted({ branch, worktreePath, title: humanizeSlug(base) });
    return session;
  }

  /**
   * Promote a draft session on its first message: create its worktree + agent.
   * On failure, routes the error through the session's own event pipeline
   * ({@link Session.recordError} → persisted, monotonic seq) instead of
   * throwing a bare error the caller must hand-build an event for, and returns
   * `false` so the caller skips delivering the turn. Returns `true` on success
   * (or when the session was not pending).
   */
  async promotePendingSession(session: Session, firstMessage: string): Promise<boolean> {
    if (!session.pending) return true;
    // Collapse concurrent first-message promotions onto one in-flight promise:
    // two callers both seeing phase "draft" must NOT each create a worktree +
    // adapter. The second caller awaits the same result the first produces.
    const existing = this.promoteInFlight.get(session.id);
    if (existing) return existing;

    const task = (async () => {
      try {
        await this.startPendingSession(session.id, firstMessage);
        return true;
      } catch (e) {
        session.recordError(`could not create worktree: ${(e as Error).message}`);
        return false;
      }
    })();
    this.promoteInFlight.set(session.id, task);
    try {
      return await task;
    } finally {
      this.promoteInFlight.delete(session.id);
    }
  }

  /**
   * Fork (once) or reuse the shared worktree for a virtual-worktree id. The
   * first sibling draft to send a message forks the tree off its base branch
   * and records `{ path, branch }`; later siblings get the same result. A
   * per-id in-flight promise collapses two drafts racing to send first onto a
   * single fork. For a non-git project (or unborn HEAD) both siblings simply
   * share the repo dir.
   */
  private async materializeVirtualWorktree(
    virtualWorktreeId: string,
    repoPath: string,
    requestedBase: string | undefined,
    fallbackBranch: string,
  ): Promise<{ path: string; branch: string }> {
    const done = this.virtualWorktrees.get(virtualWorktreeId);
    if (done) return done;
    const inflight = this.vwInFlight.get(virtualWorktreeId);
    if (inflight) return inflight;
    const task = (async () => {
      let path = repoPath;
      let branch = fallbackBranch;
      if (await isGitRepo(repoPath)) {
        const baseBranch =
          requestedBase && (await branchExists(repoPath, requestedBase))
            ? requestedBase
            : await detectDefaultBranch(repoPath);
        if (baseBranch) {
          branch = await this.uniqueBranch(repoPath, fallbackBranch);
          path = await addWorktree({ repoPath, name: branch, branch, baseBranch });
        }
      }
      const result = { path, branch };
      this.virtualWorktrees.set(virtualWorktreeId, result);
      return result;
    })();
    this.vwInFlight.set(virtualWorktreeId, task);
    try {
      return await task;
    } finally {
      this.vwInFlight.delete(virtualWorktreeId);
    }
  }

  /** Find an unused branch name, appending `-2`, `-3`, … on collision. */
  private async uniqueBranch(repoPath: string, base: string): Promise<string> {
    let candidate = base;
    let n = 1;
    while (await branchExists(repoPath, candidate)) {
      n += 1;
      candidate = `${base}-${n}`;
    }
    return candidate;
  }

  /**
   * Repo-centric snapshot for the home screen: each project enriched with its
   * default/current branch and worktrees (diff stats, open PR, running
   * sessions). Shells out to git/gh per worktree — projects and worktrees are
   * processed in parallel so the snapshot cost is roughly the slowest single
   * repo, not the sum of all of them. Callers should still treat this as an
   * occasional (connect / spawn / refresh) operation, not per-event.
   *
   * `includePrs` (default true) gates the open-PR lookup. The diff +/- numbers
   * are pure local git and instant; the PR lookup shells out to `gh` (network,
   * seconds). Pass `false` to get the fast git-only snapshot, then call
   * {@link enrichPrs} on the result to add PR info without redoing the git
   * work — so the numbers never wait on the network.
   */
  async listRepos(opts: { includePrs?: boolean } = {}): Promise<RepoDTO[]> {
    const includePrs = opts.includePrs ?? true;
    return listRepos(this.listProjects(), this.allSessions(), includePrs);
  }

  /**
   * Add open-PR info (via `gh`, network) to a git-only snapshot from
   * {@link listRepos}. Returns new objects — the input is not mutated — so the
   * caller can keep the fast snapshot around while this one is in flight. The
   * `gh` lookups are flattened across all repos and run through a single
   * bounded pool, so a many-worktree install can't launch hundreds of
   * concurrent `gh` processes / network calls.
   */
  async enrichPrs(repos: RepoDTO[]): Promise<RepoDTO[]> {
    return enrichPrs(repos);
  }

  /** List a project's prior on-disk pi sessions (newest first). */
  listPiSessions(projectId: string): PiSessionMeta[] {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    return listPiSessions(project.dto.path).map((m) => ({
      ...m,
      // A past session is "alive" when attached to a live makit session.
      attached:
        this.attachedByPi.has(m.piSessionId) &&
        this.sessions.has(this.attachedByPi.get(m.piSessionId)!),
    }));
  }

  /**
   * Resume a prior on-disk pi session: backfill its full transcript into a new
   * makit session, then launch pi with `--session <path>` to continue it live.
   * Idempotent — attaching the same pi session twice returns the existing
   * makit session (never two pi processes on one file).
   */
  async attachPiSession(projectId: string, piSessionId: string): Promise<Session> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);

    const existingId = this.attachedByPi.get(piSessionId);
    if (existingId) {
      const existing = this.sessions.get(existingId);
      if (existing) return existing;
      this.attachedByPi.delete(piSessionId);
    }

    // Collapse concurrent attaches of the same pi session onto one in-flight
    // promise so we never launch two pi processes against one transcript file.
    const pending = this.attachInFlight.get(piSessionId);
    if (pending) return pending;

    const task = (async () => {
      const meta = listPiSessions(project.dto.path).find((m) => m.piSessionId === piSessionId);
      if (!meta) throw new Error(`unknown pi session: ${piSessionId}`);
      const session = await this.createSession(project, {
        title: meta.name,
        resumeSessionPath: meta.path,
        backfill: parseTranscript(meta.path),
      });
      this.attachedByPi.set(piSessionId, session.id);
      return session;
    })();
    this.attachInFlight.set(piSessionId, task);
    try {
      return await task;
    } finally {
      this.attachInFlight.delete(piSessionId);
    }
  }

  /** Kill a session's agent process and drop it from the registry. */
  async killSession(id: string): Promise<void> {
    const session = this.sessions.get(id);
    if (!session) throw new Error(`no such session: ${id}`);

    await session.adapter.kill();
    this.sessions.delete(id);
    // Drop any attach mapping so the underlying pi session can be re-attached.
    for (const [piId, sid] of this.attachedByPi) {
      if (sid === id) this.attachedByPi.delete(piId);
    }
  }

  /** Shared session construction for spawn + attach. */
  private async createSession(
    project: ProjectEntry,
    opts: { title?: string; resumeSessionPath?: string; agent?: string; backfill?: import("./adapters/adapter.js").AdapterEvent[] },
  ): Promise<Session> {
    // Resolve the concrete agent for this session (falls back to the host default).
    const agentId = opts.agent ?? this.defaultAgentId;
    // Create the session first so we have an id to thread into the bridge.
    // askUser is threaded through `start()` below (same as PiAdapter), not the
    // constructor — keeps the adapter construction uniform across agent types.
    const built = buildAdapter(agentId);
    const adapter = built.adapter;
    const session = new Session({
      projectId: project.dto.id,
      agent: this.adapterFactory ? "stub" : built.agent,
      title: opts.title ?? DEFAULT_SESSION_TITLE,
      adapter,
      store: this.store,
      resumeSessionPath: opts.resumeSessionPath,
    });
    const activeAdapter = this.adapterFactory?.({
      projectPath: project.dto.path,
      sessionId: session.id,
      agent: agentId,
    }) ?? adapter;
    if (activeAdapter !== adapter) session.replaceAdapter(activeAdapter);

    // Seed history BEFORE the adapter goes live so it precedes new events.
    if (opts.backfill && opts.backfill.length > 0) session.backfill(opts.backfill);

    await activeAdapter.start(this.startOpts(project.dto.path, session.id, opts.resumeSessionPath));
    this.sessions.set(session.id, session);
    this.emit("sessionCreated", session);
    return session;
  }

  /**
   * Build the {@link SpawnOpts} for launching an agent adapter — the bridge
   * env/extensions/askUser wiring shared by fresh spawns and re-attaches.
   */
  private startOpts(
    projectPath: string,
    sessionId: string,
    resumeSessionPath?: string,
  ): import("./adapters/adapter.js").SpawnOpts {
    return {
      cwd: projectPath,
      sessionId,
      resumeSessionPath,
      model: this.defaultModel,
      env: this.bridge
        ? {
            MAKIT_BRIDGE_URL: this.bridge.url,
            MAKIT_BRIDGE_TOKEN: this.bridge.token,
            MAKIT_SESSION_ID: sessionId,
          }
        : undefined,
      extensions: this.bridge ? this.bridge.extensionPaths : [],
      askUser: this.bridge?.askUser,
    };
  }

  /**
   * Re-attach a cold (rehydrated) session to a live agent after a server
   * restart. Rebuilds the real adapter (pi resumes from its persisted on-disk
   * transcript via {@link startOpts}), swaps it in with {@link Session.replaceAdapter},
   * and starts it. The durable `seq` space is preserved: new events continue
   * after the persisted max (the store assigns the next seq on append), so
   * mobile↔desktop handoff survives a restart end-to-end.
   *
   * Only pi-backed sessions can resume today; other agents stay history-only
   * and keep emitting the cold-session `session.error` on send.
   */
  async reattachSession(sessionId: string): Promise<Session> {
    const session = this.sessions.get(sessionId);
    if (!session) throw new Error(`no such session: ${sessionId}`);

    const resumeSessionPath = session.resumeSessionPath;
    if (!resumeSessionPath) {
      throw new Error(`session ${sessionId} cannot be re-attached — history only`);
    }
    // Real (non-stubbed) hosts can only resume native pi from a transcript.
    if (!this.adapterFactory && session.agent !== "pi") {
      throw new Error(`cannot re-attach agent "${session.agent}" — history only`);
    }

    // cwd: the session's project if still known, else the first project.
    const project = this.projects.get(session.projectId) ?? [...this.projects.values()][0];
    const cwd = project?.dto.path ?? process.cwd();

    const adapter = this.adapterFactory
      ? this.adapterFactory({ projectPath: cwd, sessionId: session.id, agent: "pi" })
      : buildAdapter("pi").adapter;
    session.replaceAdapter(adapter);
    await adapter.start(this.startOpts(cwd, session.id, resumeSessionPath));
    return session;
  }
  /** Ensure each project has at least one default session. Convenience for M0. */
  async ensureDefaultSessions() {
    for (const p of this.projects.values()) {
      const hasOne = [...this.sessions.values()].some((s) => s.projectId === p.dto.id);
      if (!hasOne) await this.spawnPiSession(p.dto.id, DEFAULT_SESSION_TITLE);
    }
  }

  /** All sessions (for fan-out on new connections). */
  allSessions(): Session[] {
    return [...this.sessions.values()];
  }
}

/** Turn a kebab slug into a human title, e.g. "add-login-form" → "Add login form". */
function humanizeSlug(slug: string): string {
  const words = slug.split("-").filter(Boolean);
  if (words.length === 0) return DEFAULT_SESSION_TITLE;
  const joined = words.join(" ");
  return joined.charAt(0).toUpperCase() + joined.slice(1);
}
