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
import { MirrorAdapter } from "./adapters/mirror.js";
import { herdrReader, paneAgentInfo } from "./pane/herdr.js";
import { Session } from "./session.js";
import type { ProjectDTO } from "./protocol.js";
import { listPiSessions, parseTranscript, type PiSessionMeta } from "./pi-sessions.js";

export interface AdapterFactoryContext {
  projectPath: string;
  sessionId: string;
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
  /** pi session uuid → live pino session id, so re-attach reuses the process. */
  private readonly attachedByPi = new Map<string, string>();
  /** In-flight attaches, so concurrent attach calls collapse onto one process. */
  private readonly attachInFlight = new Map<string, Promise<Session>>();
  private readonly adapterFactory?: AdapterFactory;
  private readonly onProjectsChanged?: (paths: string[]) => void;
  private bridge?: BridgeBinding;

  constructor(opts: ManagerOpts) {
    super();
    this.adapterFactory = opts.adapterFactory;
    this.onProjectsChanged = opts.onProjectsChanged;
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
   *  the pino-pi extension for AskUserQuestion round-trip. */
  setBridge(bridge: BridgeBinding) {
    this.bridge = bridge;
  }

  /** Spawn a fresh pi session inside `projectId`. */
  async spawnPiSession(projectId: string, title?: string): Promise<Session> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    return this.createSession(project, { title });
  }

  /** List a project's prior on-disk pi sessions (newest first). */
  listPiSessions(projectId: string): PiSessionMeta[] {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);
    return listPiSessions(project.dto.path).map((m) => ({
      ...m,
      // A past session is "alive" when attached to a live pino session.
      attached:
        this.attachedByPi.has(m.piSessionId) &&
        this.sessions.has(this.attachedByPi.get(m.piSessionId)!),
    }));
  }

  /**
   * Resume a prior on-disk pi session: backfill its full transcript into a new
   * pino session, then launch pi with `--session <path>` to continue it live.
   * Idempotent — attaching the same pi session twice returns the existing
   * pino session (never two pi processes on one file).
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

  /**
   * Mirror a real `pi` TUI running in a multiplexer pane (World B): tail its
   * session file for output and inject the phone's input via send-keys. No pi
   * process is spawned — the TUI stays the sole writer of the session file.
   * If `sessionPath` is omitted, the most-recent session for the project is used.
   */
  async mirrorTuiSession(opts: {
    paneTarget: string;
    sessionPath?: string;
    projectId?: string;
    title?: string;
  }): Promise<Session> {
    // Auto-discover the pane's agent session + cwd from herdr when not given.
    const info =
      !opts.sessionPath || !opts.projectId
        ? await paneAgentInfo(opts.paneTarget)
        : {};

    // Project: explicit id → match a project whose path contains the pane cwd
    // → first project.
    let project = opts.projectId ? this.projects.get(opts.projectId) : undefined;
    if (!project && info.cwd) {
      project = [...this.projects.values()].find((p) =>
        info.cwd!.startsWith(p.dto.path),
      );
    }
    if (!project) project = [...this.projects.values()][0];
    if (!project) throw new Error("no project for mirror session");

    const sessionPath =
      opts.sessionPath ?? info.sessionPath ?? listPiSessions(project.dto.path)[0]?.path;
    if (!sessionPath) {
      throw new Error(`no session file found for pane ${opts.paneTarget}`);
    }

    const adapter = new MirrorAdapter(sessionPath, opts.paneTarget, herdrReader);
    const session = new Session({
      projectId: project.dto.id,
      agent: "pi",
      title: opts.title ?? `TUI ${opts.paneTarget}`,
      adapter,
    });
    await adapter.start({ cwd: project.dto.path });
    this.sessions.set(session.id, session);
    this.emit("sessionCreated", session);
    return session;
  }

  /** Shared session construction for spawn + attach. */
  private async createSession(
    project: ProjectEntry,
    opts: { title?: string; resumeSessionPath?: string; backfill?: import("./adapters/adapter.js").AdapterEvent[] },
  ): Promise<Session> {
    // Create the session first so we have an id to thread into the bridge.
    const adapter = new PiAdapter();
    const session = new Session({
      projectId: project.dto.id,
      agent: this.adapterFactory ? "stub" : "pi",
      title: opts.title ?? (this.adapterFactory ? "stub session" : "pi session"),
      adapter,
    });
    const activeAdapter = this.adapterFactory?.({
      projectPath: project.dto.path,
      sessionId: session.id,
    }) ?? adapter;
    if (activeAdapter !== adapter) session.replaceAdapter(activeAdapter);

    // Seed history BEFORE the adapter goes live so it precedes new events.
    if (opts.backfill && opts.backfill.length > 0) session.backfill(opts.backfill);

    await activeAdapter.start({
      cwd: project.dto.path,
      sessionId: session.id,
      resumeSessionPath: opts.resumeSessionPath,
      env: this.bridge
        ? {
            PINO_BRIDGE_URL: this.bridge.url,
            PINO_BRIDGE_TOKEN: this.bridge.token,
            PINO_SESSION_ID: session.id,
            ...(this.bridge.agentDir
              ? { PI_CODING_AGENT_DIR: this.bridge.agentDir }
              : {}),
          }
        : undefined,
      extensions: this.bridge ? this.bridge.extensionPaths : [],
      askUser: this.bridge?.askUser,
    });
    this.sessions.set(session.id, session);
    this.emit("sessionCreated", session);
    return session;
  }
  /** Ensure each project has at least one default session. Convenience for M0. */
  async ensureDefaultSessions() {
    for (const p of this.projects.values()) {
      const hasOne = [...this.sessions.values()].some((s) => s.projectId === p.dto.id);
      if (!hasOne) await this.spawnPiSession(p.dto.id, "new session");
    }
  }

  /** All sessions (for fan-out on new connections). */
  allSessions(): Session[] {
    return [...this.sessions.values()];
  }
}
