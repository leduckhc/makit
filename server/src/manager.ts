/**
 * SessionManager: owns projects & sessions. M0 is hardcoded to one
 * project (the server's cwd, or one passed via --project) with one
 * default pi session — enough to validate end-to-end.
 *
 * Multi-project / multi-session arrives with the home-screen FAB in M3.
 */

import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import type { AgentAdapter } from "./adapters/adapter.js";
import type { AskUser } from "./uicall.js";
import { PiAdapter } from "./adapters/pi.js";
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
  private bridge?: BridgeBinding;

  constructor(opts: ManagerOpts) {
    super();
    this.adapterFactory = opts.adapterFactory;
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
    return listPiSessions(project.dto.path);
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
