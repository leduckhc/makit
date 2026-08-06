/**
 * SessionManager: owns projects & sessions. M0 is hardcoded to one
 * project (the server's cwd, or one passed via --project) with one
 * default pi session — enough to validate end-to-end.
 *
 * Multi-project / multi-session arrives with the home-screen FAB in M3.
 */

import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { basename, resolve, join } from "node:path";
import type { AgentAdapter } from "./adapters/adapter.js";
import type { AskUser } from "./uicall.js";
import { listAgents, fingerprintAgent, type AgentDescriptor } from "./adapters/catalog.js";
import { CapabilityCache } from "./adapters/capability_cache.js";
import { Session } from "./session.js";
import { DEFAULT_SESSION_TITLE, type ProjectDTO, type RepoDTO, type SessionConfigOption, type SessionDTO } from "./protocol.js";
import { listPiSessions, parseTranscript, type PiSessionMeta } from "./pi-sessions.js";
import { DetachedAdapter } from "./adapters/detached.js";
import { buildAdapter, piAcpSpec } from "./agent_factory.js";
import { listAcpSessions } from "./adapters/acp.js";
import { listCodexThreads } from "./adapters/codex.js";
import type { AgentSessionInfo } from "./adapters/adapter.js";
import { listRepos, enrichPrs, type LastKnownPr } from "./repo_service.js";
import { createGithubGateway, type GithubGateway } from "./github/gateway.js";
import type { PersistedProject } from "./project-store.js";
import {
  isGitRepo,
  detectDefaultBranch,
  listWorktrees,
  addWorktree,
  addWorktreeForPr,
  removeWorktree,
  renameBranch,
  deleteBranch,
  syncBaseBranch,
  listOpenPrs,
  findOpenPr,
  branchExists,
  slugify,
  slugifyBranch,
  worktreeBaseDir,
  run,
  type OpenPr,
} from "./git.js";
import type { PrMutation } from "./github/queries.js";
import type { EventStore } from "./storage/event_store.js";
import { log } from "./log.js";

/**
 * What a {@link SessionManager.wrapUpWorktree} run actually did. The base-branch
 * leg is advisory (see the method doc), so the caller reports it rather than
 * treating a skip as an error.
 */
export interface WrapUpResult {
  /** The local branch that was deleted, or undefined for a detached worktree. */
  branchDeleted?: string;
  /**
   * Why the branch survived, when it should have gone. Like {@link baseReason},
   * this is reported rather than thrown: the worktree is already removed by then,
   * and the caller cannot retry because the path is no longer a worktree.
   */
  branchReason?: string;
  /** The branch that was caught up, or undefined when none could be resolved. */
  baseBranch?: string;
  baseUpdated: boolean;
  /** Why the base branch was not updated, when that is worth surfacing. */
  baseReason?: string;
}

export interface AdapterFactoryContext {
  projectPath: string;
  sessionId: string;
  /** Resolved agent id for this session (e.g. "pi", "codex"). */
  agent: string;
}

export type AdapterFactory = (context: AdapterFactoryContext) => AgentAdapter;

/**
 * One row of the adapter-native session list (SPEC-29). Mirrors the legacy
 * {@link PiSessionMeta} wire fields (so the app's `PiSessionMeta.fromJson`
 * keeps working) minus the server-internal `path`, plus the owning `agent` so
 * the client knows which harness to resume with.
 */
export interface AgentSessionListItem {
  piSessionId: string;
  agent: string;
  name: string;
  preview: string;
  messageCount: number;
  lastActivityAt: number;
  attached: boolean;
}

export interface ManagerOpts {
  /** Project roots to expose. A bare path string gets a fresh server-generated
   *  id; a `{ id, path }` record (restored from persistence) keeps its id so
   *  ids stay stable across restarts. */
  projects: Array<string | PersistedProject>;
  /** Override the production pi adapter, used by deterministic e2e tests. */
  adapterFactory?: AdapterFactory;
  /**
   * Called with the current `{ id, path }` list after every add/remove so the
   * caller can persist them (ids included, so they survive a restart).
   * Injected to keep the manager fs-agnostic.
   */
  onProjectsChanged?: (projects: PersistedProject[]) => void;
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
  /**
   * Capability cache for `agents.list`/`agents.refresh` (SPEC-27). Injected in
   * tests with a stub prober so listing never spawns a probe subprocess; a
   * default (real-probe) cache is created lazily when omitted.
   */
  capabilityCache?: CapabilityCache;
  /**
   * The single GitHub gateway (SPEC-32): every `gh` read for PR data routes
   * through it so cost, cache, dedupe, and quota accounting live in one place.
   * Injected so tests can substitute a fake (no subprocesses); omitted in
   * production, where a real gateway over git.ts's `run` is created lazily.
   */
  gateway?: GithubGateway;
}

export interface BridgeBinding {
  url: string;
  token: string;
  /** Absolute paths to connector `.ts` files (loaded via `pi -e`). */
  extensionPaths: string[];
  /**
   * Present a UICall on the phone and resolve with the answer. Threaded into an
   * adapter's `start()` so agents can transport interactive prompts (pi's
   * `ctx.ui.*` over ACP, or ACP permission/elicitation) to the app.
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
  /** Tail of the per-repo worktree-creation chain (see withWorktreeCreateLock). */
  private readonly worktreeCreateLock = new Map<string, Promise<unknown>>();
  private readonly adapterFactory?: AdapterFactory;
  private readonly onProjectsChanged?: (projects: PersistedProject[]) => void;
  private readonly defaultModel?: string;
  private readonly defaultAgentId: string;
  private readonly store?: EventStore;
  private capabilityCache?: CapabilityCache;
  private bridge?: BridgeBinding;
  private readonly _gateway: GithubGateway;

  constructor(opts: ManagerOpts) {
    super();
    this.adapterFactory = opts.adapterFactory;
    this.onProjectsChanged = opts.onProjectsChanged;
    this.defaultModel = opts.defaultModel;
    this.defaultAgentId = "pi";
    this.store = opts.store;
    this.capabilityCache = opts.capabilityCache;
    // The single GitHub gateway (SPEC-32). A real one over git.ts's `run` unless
    // a fake is injected; `run` resolves `gh` via PATH, so the test PATH-shim
    // keeps working. Constructed here does NOT self-refresh (no subprocess).
    this._gateway = opts.gateway ?? createGithubGateway({ exec: run });
    for (const entry of opts.projects) {
      // A bare path gets a fresh server-generated id; a restored `{ id, path }`
      // keeps its id so a client's persisted projectId stays valid across a
      // server restart.
      const path = typeof entry === "string" ? entry : entry.path;
      const id = typeof entry === "string" ? randomUUID() : entry.id;
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
        agentSessionId: meta.agentSessionId,
        branch: meta.branch,
        worktreePath: meta.worktreePath,
        archived: meta.archived,
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
    this.onProjectsChanged?.(
      [...this.projects.values()].map((p) => ({ id: p.dto.id, path: p.dto.path })),
    );
  }

  listSessions() {
    // Archived sessions (SPEC-29) are hidden from the ACTIVE list, but kept in
    // the registry (resumable + restorable). `allSessions()` still returns them
    // for fan-out/lookup; only this DTO list excludes them.
    return [...this.sessions.values()].filter((s) => !s.archived).map((s) => s.toDTO());
  }

  /** The archived sessions (SPEC-29), for the "Show archived" list. Newest first.
   *  Each is tagged `orphaned` when its recorded worktree is no longer an active
   *  worktree of the project (e.g. the worktree was removed) so the UI can flag
   *  it with a "worktree removed" chip. Restoring such a session runs it at the
   *  repo root (see {@link unarchiveSession}) — there is no recreate-worktree
   *  path. Sessions whose project has been removed are omitted entirely —
   *  they're unreachable (no repo/cwd). */
  async listArchivedSessions(): Promise<SessionDTO[]> {
    const archived = [...this.sessions.values()].filter((s) => s.archived);
    const liveByProject = new Map<string, Set<string>>();
    const out: SessionDTO[] = [];
    for (const session of archived) {
      const project = this.projects.get(session.projectId);
      if (!project) continue; // project removed → unreachable, hide it
      let live = liveByProject.get(session.projectId);
      if (!live) {
        live = await this.liveWorktreePaths(project.dto.path);
        liveByProject.set(session.projectId, live);
      }
      const orphaned = this.isOrphaned(session.worktreePath, project.dto.path, live);
      out.push({ ...session.toDTO(), orphaned });
    }
    return out.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
  }

  /** A project's live worktree paths (one git shell), each resolved for
   *  comparison. Empty ONLY when git failed or the repo is gone — a healthy
   *  repo always lists its primary worktree — so callers treat empty as
   *  "unproven", never as "no worktrees". */
  private async liveWorktreePaths(projectPath: string): Promise<Set<string>> {
    const entries = await listWorktrees(projectPath).catch(() => []);
    return new Set(entries.map((e) => resolve(e.path)));
  }

  /** SPEC-29 "orphaned": the session's recorded worktree is no longer a live
   *  worktree of its project. A repo-root session (no distinct worktree) is
   *  never orphaned; an empty {@link liveWorktreePaths} set is unproven (git
   *  failure) → not orphaned. This single predicate drives BOTH the archive
   *  view's "worktree removed" chip and the detach-to-root on unarchive, so the
   *  flag a user sees and the action a restore takes can never diverge. */
  private isOrphaned(worktreePath: string | undefined, projectPath: string, live: Set<string>): boolean {
    if (worktreePath == null) return false;
    const wt = resolve(worktreePath);
    if (wt === resolve(projectPath)) return false; // repo root is never orphaned
    return live.size > 0 && !live.has(wt);
  }

  getSession(id: string): Session | undefined {
    return this.sessions.get(id);
  }

  /** Set the loopback bridge + askUser wiring so subsequently-spawned
   *  sessions can transport interactive prompts (`ctx.ui.*` / ACP
   *  permission/elicitation) to the app. */
  setBridge(bridge: BridgeBinding) {
    this.bridge = bridge;
  }

  /** Spawn a fresh session inside `projectId` (default agent when unspecified). */
  async spawnPiSession(projectId: string, title?: string, agent?: string): Promise<Session> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    return this.createSession(project, { title, agent });
  }

  /** Agents this host can offer for selection in the app (base descriptors). */
  listAgents(): AgentDescriptor[] {
    return listAgents();
  }

  /** Lazily construct the capability cache (default real-probe cache). */
  private getCapabilityCache(): CapabilityCache {
    return (this.capabilityCache ??= new CapabilityCache());
  }

  /**
   * Agents enriched with their cached `configOptions` catalog (SPEC-27). Serves
   * from the capability cache, re-probing an AVAILABLE harness once on a
   * fingerprint miss/change; a warm cache spawns nothing. Unavailable harnesses
   * are never probed. This is the `agents.list` serve path.
   */
  async listAgentsWithCapabilities(): Promise<AgentDescriptor[]> {
    const cache = this.getCapabilityCache();
    return Promise.all(listAgents().map((d) => cache.serve(d)));
  }

  /**
   * Force a re-probe of one harness and return its fresh descriptor
   * (`agents.refresh`). Returns `undefined` for an unknown agent id.
   */
  async refreshAgent(agentId: string): Promise<AgentDescriptor | undefined> {
    const descriptor = listAgents().find((a) => a.id === agentId);
    if (!descriptor) return undefined;
    return this.getCapabilityCache().refresh(descriptor);
  }

  /**
   * Validate pre-spawn config picks against the AGENT's cached catalog: drop
   * unknown option ids and values that aren't offered, keep the valid ones
   * (SPEC-27). When no catalog is cached yet (cold probe), picks pass through
   * unchanged — apply-at-launch is best-effort and the live session reconciles.
   */
  private validateConfigPicks(
    agentId: string,
    picks: { id: string; value: string | boolean }[],
  ): { id: string; value: string | boolean }[] {
    const fingerprint = fingerprintAgent(agentId);
    const cache = this.capabilityCache ?? this.getCapabilityCache();
    const cached = cache.get(agentId);
    // Only trust the catalog when it matches the current fingerprint.
    const catalog =
      cached && cached.fingerprint === fingerprint ? cached.configOptions : undefined;
    if (!catalog) return picks;
    return picks.filter((pick) => isValidPick(catalog, pick));
  }

  /**
   * Spawn a session for a chosen agent. All sessions run headless (SPEC-27):
   * pi over ACP via `pi-acp`, codex via `codex app-server`. There is no longer
   * an attachable multiplexer pane.
   */
  async spawnSession(projectId: string, title?: string, agent?: string): Promise<Session> {
    const agentId = agent ?? this.defaultAgentId;
    return this.spawnPiSession(projectId, title, agentId);
  }

  /**
   * Spawn a DRAFT session: no agent process yet. Agent creation is deferred
   * until the first substantive user message (see {@link startPendingSession}),
   * which names the session. `worktreePath` is the worktree the client already
   * resolved (creating it when needed); without one the agent runs in the repo
   * dir (non-git project / unborn HEAD). Uses a {@link DetachedAdapter}
   * placeholder so the session wires + shows in snapshots immediately.
   */
  async spawnPendingSession(projectId: string, agent?: string, worktreePath?: string, branch?: string, configOptions?: { id: string; value: string | boolean }[]): Promise<Session> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    const agentId = agent ?? this.defaultAgentId;
    // Validate pre-spawn picks against the cached catalog now (drop unknown
    // ids/values); the survivors ride the draft and apply at launch (SPEC-27).
    const configPicks =
      configOptions && configOptions.length > 0
        ? this.validateConfigPicks(agentId, configOptions)
        : undefined;
    // The path comes from the wire, so verify it is genuinely a worktree of this
    // project (or the project dir itself, which is what `createWorktree` returns
    // for a non-git project) and derive the branch from git rather than trusting
    // the client — otherwise a client could launch an agent outside the project.
    let boundPath: string | undefined;
    let boundBranch: string | undefined;
    if (worktreePath) {
      if (resolve(worktreePath) === resolve(project.dto.path)) {
        boundPath = project.dto.path;
        // Keep the client's branch. Dropping it here meant promotion fell back
        // to `lc.branch ?? base` and labelled a session running in the primary
        // checkout with the slugified first message instead of its real branch.
        boundBranch = branch;
      } else {
        const entries = await listWorktrees(project.dto.path);
        const match = entries.find(
          (e) => resolve(e.path) === resolve(worktreePath),
        );
        if (!match) {
          throw new Error(
            `worktree is not part of project ${projectId}: ${worktreePath}`,
          );
        }
        boundPath = match.path;
        boundBranch = match.branch ?? branch;
      }
    }
    const session = new Session({
      projectId: project.dto.id,
      agent: this.adapterFactory ? "stub" : agentId,
      title: DEFAULT_SESSION_TITLE,
      adapter: new DetachedAdapter(agentId),
      store: this.store,
    });
    session.beginDraft({
      agent: agentId,
      pendingWorktreePath: boundPath,
      branch: boundBranch,
      configPicks,
    });
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
   * an auto-generated branch name (or a slugified `branchName` when supplied),
   * WITHOUT a session (the + New worktree flow).
   * The worktree exists immediately; the session is started later once the
   * user picks a harness and sends the first message (see spawnPendingSession
   * with a bound worktreePath). For a non-git project, returns the repo dir.
   */
  async createWorktree(
    projectId: string,
    baseBranch?: string,
    branchName?: string,
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
    // A user-supplied name is slugified to a git-safe ref; blank/invalid names
    // fall back to the auto-generated `worktree-<uuid>`. `slugifyBranch` keeps
    // `/` so hierarchical names like `feat/new-ui` survive as-is; either way
    // `uniqueBranch` guards against collisions.
    const requested = branchName ? slugifyBranch(branchName) : "";
    // Serialize per repo so the pick-unique-name → `git worktree add` sequence
    // is atomic against other concurrent creations (avoids a TOCTOU race on
    // both the branch ref and the flattened directory).
    return this.withWorktreeCreateLock(repoPath, async () => {
      const branch = await this.uniqueBranch(
        repoPath,
        requested || `worktree-${randomUUID().slice(0, 6)}`,
      );
      // The worktree DIRECTORY can't contain `/` (it would nest a subfolder),
      // so flatten it while the branch keeps its slashes: `feat/new-ui` on disk
      // becomes `feat-new-ui`. Because distinct branches can flatten to the
      // same dir (`feat/new-ui` vs an existing `feat-new-ui`), disambiguate the
      // dir separately — branch uniqueness alone no longer guarantees a free
      // path.
      const dirName = this.uniqueWorktreeDir(repoPath, branch.replace(/\//g, "-"));
      const path = await addWorktree({
        repoPath,
        name: dirName,
        branch,
        baseBranch: base,
      });
      return { path, branch };
    });
  }

  /**
   * Open PRs for a project, for the "New worktree from PR" picker.
   *
   * Marked `interactive`: this is a click, so it draws on the quota reserve
   * (SPEC-32 §6.3). A throttled account is precisely when the user reaches for
   * the picker, and a silently empty list would read as "no open PRs".
   */
  async listOpenPrs(projectId: string): Promise<OpenPr[]> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    return listOpenPrs(this._gateway, project.dto.path, undefined, { interactive: true });
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
    const prs = await listOpenPrs(this._gateway, repoPath);
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
    if (await findOpenPr(this._gateway, repoPath, oldName)) {
      throw new Error(`cannot rename ${oldName}: it has an open pull request`);
    }
    await renameBranch(worktreePath, oldName, newName);
  }

  /**
   * Discard a worktree whose pull request closed without merging (SPEC-38 §6.1):
   * remove the worktree, then delete the branch it held.
   *
   * Symmetric with {@link wrapUpWorktree} minus the base-branch sync — nothing
   * landed, so there is nothing for the base to catch up to. Deleting the branch
   * is safe enough to be the default: a pull request cannot exist without a
   * pushed head, so the commits remain on `origin/<branch>` and a local delete is
   * recoverable by re-fetch. The app confirms first and names the branch.
   *
   * Distinct from {@link removeWorktree}, which the sidebar and the mobile
   * long-press use and which deliberately keeps the branch — "remove this
   * worktree" is a narrower request than "discard this dead line of work".
   */
  async discardWorktree(projectId: string, worktreePath: string): Promise<WrapUpResult> {
    const { branchDeleted, branchReason } = await this._removeWorktreeAndBranch(
      projectId,
      worktreePath,
    );
    return { branchDeleted, branchReason, baseUpdated: false };
  }

  /**
   * The half {@link wrapUpWorktree} and {@link discardWorktree} share: read the
   * branch (only possible while the worktree still exists), remove the worktree,
   * then delete the branch.
   *
   * The removal throws — if the worktree survives, nothing was tidied and the
   * caller should say so. The branch deletion does **not**: by then the worktree
   * is gone, the client cannot retry (the path is no longer a registered
   * worktree), and reporting a partial success beats reporting a total failure.
   */
  private async _removeWorktreeAndBranch(
    projectId: string,
    worktreePath: string,
  ): Promise<{ repoPath: string; branchDeleted?: string; branchReason?: string }> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    const repoPath = project.dto.path;
    const target = resolve(worktreePath);
    const trees = await listWorktrees(repoPath);
    const branch = trees.find((t) => resolve(t.path) === target)?.branch ?? null;

    await this.removeWorktree(projectId, worktreePath);
    if (!branch) return { repoPath };
    try {
      await deleteBranch(repoPath, branch);
      return { repoPath, branchDeleted: branch };
    } catch (e) {
      log.warn(`[makit] wrap up: could not delete ${branch}: ${(e as Error).message}`);
      return { repoPath, branchReason: (e as Error).message };
    }
  }

  /**
   * Take the worktree's pull request out of draft (`gh pr ready`).
   *
   * Reviewers get notified, so this is a real state change on GitHub — but it is
   * reversible (`gh pr ready --undo`) and destroys nothing, which is why the app
   * runs it straight from the bar without a confirm, unlike wrap up.
   */
  async markPrReady(projectId: string, worktreePath: string): Promise<void> {
    await this._mutatePr(projectId, worktreePath, "ready");
  }

  /**
   * Merge the base branch into the PR's head on GitHub (`gh pr update-branch`) —
   * the remedy for `mergeStateStatus: BEHIND`.
   *
   * Deliberately the *remote* operation rather than a local rebase-and-push: it
   * is what GitHub's own "Update branch" button does, it cannot conflict with
   * uncommitted work in the worktree, and it leaves the local checkout untouched
   * (the next poll reports the new state).
   */
  async updatePrBranch(projectId: string, worktreePath: string): Promise<void> {
    await this._mutatePr(projectId, worktreePath, "update-branch");
  }

  /**
   * Squash-merge the worktree's pull request (`gh pr merge --squash`), the way
   * GitHub's own button does.
   *
   * Deliberately does **not** pass `--delete-branch`: merging and tidying up are
   * two decisions, and folding them together would remove the worktree out from
   * under any session still running in it. Once merged, the PR reports `MERGED`
   * and the app offers {@link wrapUpWorktree} — which stops those sessions first.
   */
  async squashMergePr(projectId: string, worktreePath: string): Promise<void> {
    await this._mutatePr(projectId, worktreePath, "merge-squash");
  }

  /**
   * Shared body for the PR mutations: resolve the worktree's branch, look up
   * its PR, run the verb, and turn a `gh` failure into a thrown error carrying
   * gh's own message — the app puts that in front of the user, so swallowing it
   * would leave a button that silently does nothing.
   */
  private async _mutatePr(
    projectId: string,
    worktreePath: string,
    verb: PrMutation,
  ): Promise<void> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    const repoPath = project.dto.path;
    const target = resolve(worktreePath);
    const trees = await listWorktrees(repoPath);
    const wt = trees.find((t) => resolve(t.path) === target);
    if (!wt) throw new Error(`worktree is not part of project ${projectId}: ${worktreePath}`);
    const branch = wt.branch;
    if (!branch) throw new Error(`worktree has no branch: ${worktreePath}`);
    const pr = await findOpenPr(this._gateway, repoPath, branch);
    if (!pr) throw new Error(`no pull request for ${branch}`);
    const result = await this._gateway.mutatePr(repoPath, branch, pr.number, verb);
    if (!result.ok) throw new Error(result.error ?? `gh pr ${verb} failed`);
  }

  /**
   * Tidy up after a pull request ended (SPEC: PR actions, "wrap up").
   *
   * Three steps, in this order, because each one only makes sense if the
   * previous succeeded:
   *  1. remove the worktree — delegated to {@link removeWorktree}, so the
   *     session reconciliation and the primary/ownership guards are shared,
   *  2. delete the local branch it had checked out — the branch cannot be
   *     deleted while a worktree holds it, so this must come second,
   *  3. fast-forward the base branch the PR landed on.
   *
   * Step 3 is best-effort and reported, never fatal: by then the worktree is
   * already gone, so throwing would describe a mostly-done job as a failure.
   * Steps 1 and 2 do throw — if the worktree survives, nothing was tidied.
   *
   * [baseBranch] should be the PR's own `baseRefName`; it falls back to the
   * repo's default branch for an older server or a shed PR lookup.
   */
  async wrapUpWorktree(
    projectId: string,
    worktreePath: string,
    baseBranch?: string,
  ): Promise<WrapUpResult> {
    const { repoPath, branchDeleted, branchReason } =
        await this._removeWorktreeAndBranch(projectId, worktreePath);

    const base = baseBranch ?? (await detectDefaultBranch(repoPath));
    if (!base) {
      return {
        branchDeleted,
        branchReason,
        baseUpdated: false,
        baseReason: "the repo has no default branch to catch up",
      };
    }
    const sync = await syncBaseBranch(repoPath, base);
    return {
      branchDeleted,
      branchReason,
      baseBranch: base,
      baseUpdated: sync.updated,
      baseReason: sync.reason,
    };
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
    // Remove the worktree first; only tear its sessions down once git actually
    // succeeds. Killing first would orphan sessions (unrecoverably) if the
    // removal then failed, leaving the worktree on disk without its sessions.
    await removeWorktree(repoPath, worktreePath, true);
    // Reconcile sessions bound to the removed worktree (SPEC-29):
    //  - archived  → leave as-is (already preserved; it simply becomes orphaned)
    //  - draft     → kill (no transcript to keep; must not launch in a deleted dir)
    //  - live      → ARCHIVE, not kill — preserve the transcript + resume handle
    //               (mirrors close==archive). It survives as an orphaned archived
    //               session, restorable later.
    for (const session of this.sessions.values()) {
      if (session.projectId !== projectId) continue;
      const bound = session.boundWorktreePath;
      if (!bound || resolve(bound) !== target) continue;
      if (session.archived) continue;
      if (session.pending) {
        await this.killSession(session.id);
      } else {
        await this.archiveSession(session.id);
      }
    }
  }

  /**
   * Promote a pending session on its first real request: name it from
   * `firstMessage` and start the chosen agent in the worktree the draft is
   * bound to. Idempotent — a non-pending session is returned unchanged. An
   * unbound draft (non-git project / unborn HEAD) runs in the repo dir.
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
    // The worktree was resolved (and created, when the user asked for a new
    // branch) before the spawn, so promotion never forks a tree here.
    const worktreePath = lc.pendingWorktreePath ?? repoPath;
    const branch = lc.branch ?? base;

    const built = buildAdapter(agentId);
    const adapter =
      this.adapterFactory?.({ projectPath: worktreePath, sessionId: session.id, agent: agentId }) ??
      built.adapter;
    session.replaceAdapter(adapter);
    await adapter.start(this.startOpts(worktreePath, session.id));
    // Apply pre-spawn config picks now: AFTER the real session/thread exists
    // and BEFORE the first prompt (SPEC-27). Best-effort per transport — ACP
    // routes to session/set_config_option, codex caches model/effort for the
    // first turn/start; an adapter that can't honour a pick ignores it.
    await this.applyConfigPicks(adapter, lc.configPicks);
    // Persist the live adapter's native id so this session can resume after a
    // server restart (SPEC-29).
    session.captureAgentSessionId();
    session.markStarted({ branch, worktreePath, title: humanizeSlug(base) });
    return session;
  }

  /**
   * Apply carried config picks to a freshly-started session's REAL adapter via
   * the shared `configOption` action path. Best-effort: a rejected/ignored pick
   * never fails the launch (the live session's reported `configOptions` is
   * authoritative).
   */
  private async applyConfigPicks(
    adapter: AgentAdapter,
    picks: { id: string; value: string | boolean }[] | undefined,
  ): Promise<void> {
    if (!picks || picks.length === 0 || !adapter.sendAction) return;
    for (const pick of picks) {
      try {
        await adapter.sendAction("configOption", { id: pick.id, value: pick.value });
      } catch (e) {
        log.warn(`[makit] could not apply config pick ${pick.id}: ${(e as Error).message}`);
      }
    }
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
   * Serialize worktree creation per repo. Picking a unique branch/dir name and
   * then running `git worktree add` is a check-then-act sequence: two concurrent
   * creations can choose the same name between the existence check and the add,
   * making git fail (a TOCTOU race). Chaining each repo's creations one after
   * another keeps the whole pick-then-add step atomic relative to other
   * creations. The stored tail swallows rejections so one failed creation does
   * not reject the next caller; the returned promise still surfaces real errors.
   */
  private withWorktreeCreateLock<T>(repoPath: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.worktreeCreateLock.get(repoPath) ?? Promise.resolve();
    const run = prev.catch(() => {}).then(fn);
    this.worktreeCreateLock.set(repoPath, run.catch(() => {}));
    return run;
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
   * Find an unused worktree directory name under `<worktreeBaseDir>/<repoName>`,
   * appending `-2`, `-3`, … on collision. Needed because two distinct branches
   * can flatten to the same dir name (`feat/new-ui` → `feat-new-ui`), so a
   * unique branch is not enough to guarantee `git worktree add`'s target path
   * is free. Mirrors {@link addWorktree}'s target layout.
   */
  private uniqueWorktreeDir(repoPath: string, base: string): string {
    const parent = join(worktreeBaseDir(), basename(resolve(repoPath)));
    let candidate = base;
    let n = 1;
    while (existsSync(join(parent, candidate))) {
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
  async listRepos(
    opts: { includePrs?: boolean } = {},
    lastKnown: LastKnownPr = () => null,
  ): Promise<RepoDTO[]> {
    const includePrs = opts.includePrs ?? true;
    return listRepos(this.listProjects(), this.allSessions(), includePrs, this._gateway, lastKnown);
  }

  /**
   * Add open-PR info (via `gh`, network) to a git-only snapshot from
   * {@link listRepos}. Returns new objects — the input is not mutated — so the
   * caller can keep the fast snapshot around while this one is in flight. The
   * `gh` lookups are flattened across all repos and run through a single
   * bounded pool, so a many-worktree install can't launch hundreds of
   * concurrent `gh` processes / network calls.
   *
   * `lastKnown` lets a throttled/failed lookup retain the previously-broadcast
   * PR (marked `stale`) instead of erasing the pill (SPEC-32 §6.5); the caller
   * (server.ts) owns the last-broadcast snapshot. Defaults to "nothing known".
   */
  async enrichPrs(repos: RepoDTO[], lastKnown: LastKnownPr = () => null): Promise<RepoDTO[]> {
    return enrichPrs(repos, this._gateway, lastKnown);
  }

  /** The single GitHub gateway (SPEC-32), for the server's budget wiring. */
  get gateway(): GithubGateway {
    return this._gateway;
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
   * Adapter-native session discovery (SPEC-29): enumerate a project's prior
   * sessions by asking each AVAILABLE agent over its own protocol — ACP
   * `session/list` (pi via `pi-acp`) and codex `thread/list` — instead of
   * scraping pi's on-disk transcript files. Agent-agnostic (codex sessions now
   * appear) and capability-gated (an agent without listing yields nothing). One
   * throwaway connection per agent; results are merged and sorted newest-first.
   * Never throws — a failing agent contributes no rows rather than failing the
   * whole list.
   */
  async listAgentSessions(projectId: string): Promise<AgentSessionListItem[]> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    const cwd = project.dto.path;

    const perAgent = await Promise.all(
      listAgents().map(async (descriptor) => {
        try {
          const infos =
            descriptor.transport === "native"
              ? await listCodexThreads(cwd)
              : await listAcpSessions(piAcpSpec(), cwd);
          return infos.map((info) => this.toSessionListItem(info, descriptor.id));
        } catch (e) {
          // Per-agent degradation: a spawn failure (harness missing) or an
          // unreadable path must not fail the whole list — that agent just
          // contributes no rows.
          log.warn(`[makit] listAgentSessions(${descriptor.id}) failed: ${(e as Error).message}`);
          return [] as AgentSessionListItem[];
        }
      }),
    );
    return perAgent.flat().sort((a, b) => b.lastActivityAt - a.lastActivityAt);
  }

  /**
   * Normalize an {@link AgentSessionInfo} to the wire list item, tagging it with
   * the owning agent and marking `attached` when a live makit session already
   * runs this native session/thread id.
   */
  private toSessionListItem(info: AgentSessionInfo, agent: string): AgentSessionListItem {
    const attached = [...this.sessions.values()].some(
      (s) => s.agentSessionId === info.id,
    );
    return {
      piSessionId: info.id,
      agent,
      name: info.title || info.preview || new Date(info.updatedAt ?? Date.now()).toISOString(),
      preview: info.preview ?? "",
      messageCount: info.messageCount ?? 0,
      lastActivityAt: info.updatedAt ?? 0,
      attached,
    };
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

  /**
   * Archive a session (SPEC-29): a soft, recoverable hide. Sets the persisted
   * `archived` flag — so it drops from the active session list and survives a
   * restart — and stops the live agent process (archived sessions shouldn't
   * hold one), swapping in the detached placeholder. The event log + resume
   * handle are KEPT, so `unarchive` + a later subscribe resume it exactly like
   * any cold session. Deliberately makit-side only: we do NOT call the back
   * end's native archive, so the underlying session/thread stays directly
   * resumable (no archived-thread-resume edge case). Idempotent.
   */
  async archiveSession(id: string): Promise<void> {
    const session = this.sessions.get(id);
    if (!session) throw new Error(`no such session: ${id}`);
    if (session.archived) return;
    // Best-effort: archiving is the recovery path in the removeWorktree loop
    // (called after git already deleted the tree), so a rejecting kill() must
    // not abort the archive — or the reconciliation of the remaining sessions.
    try {
      await session.adapter.kill();
    } catch (e) {
      log.warn(`[makit] archiveSession(${id}): kill failed: ${(e as Error).message}`);
    }
    session.replaceAdapter(new DetachedAdapter(session.agent));
    session.setArchived(true);
  }

  /**
   * Restore an archived session (SPEC-29): clear the flag so it returns to the
   * active list. It stays cold until the next subscribe re-attaches it (resume
   * by its kept native id). Idempotent.
   */
  async unarchiveSession(id: string): Promise<void> {
    const session = this.sessions.get(id);
    if (!session) throw new Error(`no such session: ${id}`);
    // If the worktree was deleted while archived, restoring must detach the
    // session to the repo root (SPEC-29) — otherwise its stale path matches no
    // live worktree and it renders in no view. Uses the same orphaned predicate
    // as the archive-list chip, so the flag and the action never diverge;
    // reattachSession already falls back to the repo root for a missing
    // worktree, so resume is unaffected.
    const project = session.worktreePath ? this.projects.get(session.projectId) : undefined;
    if (project) {
      const live = await this.liveWorktreePaths(project.dto.path);
      if (this.isOrphaned(session.worktreePath, project.dto.path, live)) {
        session.detachToRoot();
      }
    }
    session.setArchived(false);
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
    // askUser is threaded through `start()` below (uniform across agent types),
    // not the
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
    // Persist the live adapter's native session/thread id for restart-resume.
    session.captureAgentSessionId();
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
    resumeAgentSessionId?: string,
  ): import("./adapters/adapter.js").SpawnOpts {
    return {
      cwd: projectPath,
      sessionId,
      resumeSessionPath,
      resumeAgentSessionId,
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

    // A session is resumable iff it captured a native agent session/thread id
    // (SPEC-29) OR a legacy pi resume path. The adapter itself decides how to
    // honour it (ACP session/resume|load, codex thread/resume, pi --session)
    // from its advertised capabilities; a back end that can do neither starts
    // fresh but live.
    const agentSessionId = session.agentSessionId;
    const resumeSessionPath = session.resumeSessionPath;
    if (!agentSessionId && !resumeSessionPath) {
      throw new Error(`session ${sessionId} cannot be re-attached — history only`);
    }

    // cwd: the session's own worktree when it is still an ACTIVE worktree of
    // the project AND still on disk (so the resumed agent runs on its branch,
    // not the default, and a pruned-then-recreated path is never trusted),
    // else the session's project if still known, else the first project.
    const project = this.projects.get(session.projectId) ?? [...this.projects.values()][0];
    const worktree = session.worktreePath;
    let cwd = project?.dto.path ?? process.cwd();
    if (worktree && project && existsSync(worktree)) {
      const entries = await listWorktrees(project.dto.path);
      if (entries.some((e) => resolve(e.path) === resolve(worktree))) cwd = worktree;
    }

    const adapter = this.adapterFactory
      ? this.adapterFactory({ projectPath: cwd, sessionId: session.id, agent: session.agent })
      : buildAdapter(session.agent).adapter;
    session.replaceAdapter(adapter);
    await adapter.start(this.startOpts(cwd, session.id, resumeSessionPath, agentSessionId));
    // The resumed adapter may report a new native id (e.g. an ACP agent that
    // could only start fresh); persist whatever it now holds.
    session.captureAgentSessionId();
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

/**
 * True when a pick names an option in the catalog AND supplies a value that
 * option accepts: booleans take any boolean; selects must match one of the
 * offered values (flat `options` or grouped `groups`).
 */
function isValidPick(
  catalog: SessionConfigOption[],
  pick: { id: string; value: string | boolean },
): boolean {
  const option = catalog.find((o) => o.id === pick.id);
  if (!option) return false;
  if (option.type === "boolean") return typeof pick.value === "boolean";
  if (typeof pick.value !== "string") return false;
  const flat = option.options?.some((v) => v.value === pick.value) ?? false;
  const grouped =
    option.groups?.some((g) => g.options.some((v) => v.value === pick.value)) ?? false;
  return flat || grouped;
}

/** Turn a kebab slug into a human title, e.g. "add-login-form" → "Add login form". */
function humanizeSlug(slug: string): string {
  const words = slug.split("-").filter(Boolean);
  if (words.length === 0) return DEFAULT_SESSION_TITLE;
  const joined = words.join(" ");
  return joined.charAt(0).toUpperCase() + joined.slice(1);
}
