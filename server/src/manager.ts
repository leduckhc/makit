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
import { PiAdapter } from "./adapters/pi.js";
import { AcpAdapter, codexAcpSpec } from "./adapters/acp.js";
import { CodexAppServerAdapter } from "./adapters/codex.js";
import { listAgents, type AgentDescriptor } from "./adapters/catalog.js";
import { Session } from "./session.js";
import { DEFAULT_SESSION_TITLE, type ProjectDTO } from "./protocol.js";
import { listPiSessions, parseTranscript, type PiSessionMeta } from "./pi-sessions.js";
import { DetachedAdapter } from "./adapters/detached.js";
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
  /**
   * Override for pi's config dir (PI_CODING_AGENT_DIR). Used to load a
   * filtered settings.json that excludes TUI-only packages like pi-ask.
   */
  agentDir?: string;
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
   */
  private rehydrate(): void {
    if (!this.store) return;
    for (const meta of this.store.loadSessions()) {
      const session = new Session({
        id: meta.id,
        projectId: meta.projectId,
        agent: meta.agent,
        title: meta.title,
        policy: meta.policy,
        adapter: new DetachedAdapter(meta.agent),
        store: this.store,
        createdAt: meta.createdAt,
        status: "exited",
        lastActivityAt: meta.lastActivityAt,
        lastPreview: meta.lastPreview,
        resumeSessionPath: meta.resumeSessionPath,
      });
      session.hydrate(this.store.read(meta.id));
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

  /** Set the loopback bridge so subsequently-spawned pi sessions can use
   *  the makit-pi extension for AskUserQuestion round-trip. */
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

  /** Construct the adapter for an agent id. */
  private buildAdapter(agentId: string): { agent: string; adapter: AgentAdapter } {
    switch (agentId) {
      case "codex":
        return { agent: "codex", adapter: new AcpAdapter({ spec: codexAcpSpec() }) };
      case "codex-native":
        return { agent: "codex-native", adapter: new CodexAppServerAdapter() };
      case "pi":
      default:
        return { agent: "pi", adapter: new PiAdapter() };
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
    const built = this.buildAdapter(agentId);
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
            ...(this.bridge.agentDir
              ? { PI_CODING_AGENT_DIR: this.bridge.agentDir }
              : {}),
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
      : this.buildAdapter("pi").adapter;
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
