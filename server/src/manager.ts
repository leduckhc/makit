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
import { AcpAdapter, piAcpSpec, codexAcpSpec } from "./adapters/acp.js";
import { CodexAppServerAdapter } from "./adapters/codex.js";
import { listAgents, type AgentDescriptor } from "./adapters/catalog.js";
import { MirrorAdapter } from "./adapters/mirror.js";
import { IngestAdapter } from "./adapters/ingest.js";
import { herdrReader, paneAgentInfo } from "./pane/herdr.js";
import { Session } from "./session.js";
import { DEFAULT_SESSION_TITLE, type ProjectDTO } from "./protocol.js";
import { listPiSessions, parseTranscript, type PiSessionMeta } from "./pi-sessions.js";
import { type MultiplexerAdapter, type PaneHandle, MuxError } from "./mux/adapter.js";
import { getMultiplexer } from "./mux/registry.js";
import { log } from "./log.js";

export interface AdapterFactoryContext {
  projectPath: string;
  sessionId: string;
  /** Resolved agent id for this session (e.g. "pi", "pi-acp", "codex"). */
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
   * Override the multiplexer adapter (SPEC-05). Production code uses
   * getMultiplexer(); tests inject a fake via this option.
   */
  mux?: MultiplexerAdapter | undefined;
  /**
   * Force every spawned pi session onto a specific model (`--model`). Used by
   * the real-pi e2e to select the fake model provider. Unset in production, so
   * pi uses its own configured default.
   */
  defaultModel?: string;
  /**
   * Agent adapter type: "acp" (ACP protocol via pi-acp, default) or "pi"
   * (legacy native pi RPC). The native pi path is slated for removal once ACP
   * reaches parity.
   */
  agentType?: "pi" | "acp";
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

interface PendingSpawn {
  resolve: (session: Session) => void;
  reject: (err: Error) => void;
  paneHandle: PaneHandle;
  timer: ReturnType<typeof setTimeout>;
}

const SPAWN_TIMEOUT_MS = 15_000;

export interface SpawnInPaneOpts {
  /** Override the spawn timeout (ms). Defaults to 15 s. Used by tests. */
  timeoutMs?: number;
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
  private readonly agentType: "pi" | "acp";
  private readonly defaultAgentId: string;
  private bridge?: BridgeBinding;
  /** Injected or resolved multiplexer adapter (SPEC-05). */
  private readonly _muxOverride?: MultiplexerAdapter | undefined;
  /** spawnToken → pending pane spawn waiting for host.open correlation. */
  private readonly pendingSpawns = new Map<string, PendingSpawn>();

  constructor(opts: ManagerOpts) {
    super();
    this.adapterFactory = opts.adapterFactory;
    this.onProjectsChanged = opts.onProjectsChanged;
    this._muxOverride = opts.mux;
    this.defaultModel = opts.defaultModel;
    this.agentType = opts.agentType ?? "acp";
    // Map the coarse agentType to a concrete default agent id used when a spawn
    // request doesn't specify one.
    this.defaultAgentId = this.agentType === "acp" ? "pi-acp" : "pi";
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
   * path (World B/D mirror); ACP-backed agents (pi-acp, codex) always run
   * headless since there's no real TUI to mirror.
   */
  async spawnSession(projectId: string, title?: string, agent?: string): Promise<Session> {
    const agentId = agent ?? this.defaultAgentId;
    // Only native pi mirrors a real TUI in a multiplexer pane (World B/D);
    // every other agent (pi-acp, codex, codex-native) runs headless.
    if (agentId === "pi") {
      return this.spawnPiSessionInPane(projectId, title);
    }
    return this.spawnPiSession(projectId, title, agentId);
  }

  /**
   * Spawn a pi session in a multiplexer pane (SPEC-05, World D / makit-mirror
   * path). Falls back to headless if no mux is available or the pane spawn
   * fails. A spawnToken is embedded in the pane command's env; the matching
   * `host.open` frame calls `resolvePendingSpawn` to bind the session.
   */
  async spawnPiSessionInPane(
    projectId: string,
    title?: string,
    opts: SpawnInPaneOpts = {},
  ): Promise<Session> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);

    const mux = this._muxOverride !== undefined
      ? this._muxOverride
      : getMultiplexer();

    if (!mux) return this.spawnPiSession(projectId, title);

    const available = await mux.isAvailable().catch(() => false);
    if (!available) return this.spawnPiSession(projectId, title);

    const spawnToken = randomUUID();
    const label = `makit: ${title ?? DEFAULT_SESSION_TITLE}`;
    const piBin = process.env.MAKIT_PI_BIN ?? "pi";
    const command = `MAKIT_SPAWN_TOKEN=${spawnToken} ${piBin}`;

    let paneHandle: PaneHandle;
    try {
      paneHandle = await mux.spawnPane({ cwd: project.dto.path, command, label });
    } catch (e) {
      log.warn(
        `[makit] mux pane spawn failed — falling back to headless: ${(e as Error).message}`,
      );
      if (e instanceof MuxError) {
        log.info(
          "[makit] hint: set MAKIT_MUX_ANCHOR to a valid pane id (e.g. w1:p1), not a workspace label",
        );
      }
      return this.spawnPiSession(projectId, title);
    }

    const pending = this.registerPendingSpawn(spawnToken, paneHandle, opts.timeoutMs ?? SPAWN_TIMEOUT_MS);
    try {
      return await pending;
    } catch (e) {
      await mux.closePane(paneHandle).catch(() => {});
      throw e;
    }
  }

  /**
   * Register a pending spawn waiting for the matching `host.open`.
   * Returns a promise that resolves once `resolvePendingSpawn` is called.
   * @internal called by spawnPiSessionInPane; exposed for tests via simulateHostOpen.
   */
  private registerPendingSpawn(
    spawnToken: string,
    paneHandle: PaneHandle,
    timeoutMs: number,
  ): Promise<Session> {
    return new Promise<Session>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingSpawns.delete(spawnToken);
        reject(new Error(`spawn timeout: pi did not connect within ${timeoutMs}ms`));
      }, timeoutMs);
      this.pendingSpawns.set(spawnToken, { resolve, reject, paneHandle, timer });
    });
  }

  /**
   * Called by server.ts's host.open handler when a spawnToken is present.
   * Attaches the pane handle to the session and resolves the pending promise.
   * Returns the paneHandle if found, undefined otherwise.
   */
  resolvePendingSpawn(spawnToken: string, session: Session): PaneHandle | undefined {
    const pending = this.pendingSpawns.get(spawnToken);
    if (!pending) return undefined;
    clearTimeout(pending.timer);
    this.pendingSpawns.delete(spawnToken);
    session.pane = pending.paneHandle;
    pending.resolve(session);
    return pending.paneHandle;
  }

  /**
   * Relabel the mux pane for a session when its title changes (SPEC-05).
   * No-op if the session has no pane handle or the mux doesn't support rename.
   */
  async updatePaneLabel(sessionId: string, title: string): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session?.pane) return;
    const mux = this._muxOverride !== undefined
      ? this._muxOverride
      : getMultiplexer(session.pane.mux);
    if (!mux) return;
    await mux.setLabel?.(session.pane, `makit: ${title}`).catch(() => {});
  }

  /**
   * Test helper: simulate the host.open path for a pending pane spawn.
   * Creates a minimal IngestAdapter session (without the real pi commands
   * fetcher) and resolves the pending spawn. Production code uses the
   * server.ts host.open handler which calls openHostSession then
   * resolvePendingSpawn.
   */
  async simulateHostOpen(
    spawnToken: string,
    title: string | undefined,
    cwd: string,
    projectId: string,
  ): Promise<Session> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error(`unknown project: ${projectId}`);

    // Build a minimal ingest session without enableCommands() to avoid
    // spawning a real pi subprocess in tests.
    const { IngestAdapter } = await import("./adapters/ingest.js");
    const adapter = new IngestAdapter(() => {});
    const session = new Session({
      projectId: project.dto.id,
      agent: "pi",
      title: title ?? DEFAULT_SESSION_TITLE,
      adapter,
    });
    await adapter.start({ cwd });
    this.sessions.set(session.id, session);
    this.emit("sessionCreated", session);
    this.resolvePendingSpawn(spawnToken, session);
    return session;
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

    // Close the mux pane if this session was spawned in one (SPEC-05). Idempotent.
    if (session.pane) {
      const mux = this._muxOverride !== undefined
        ? this._muxOverride
        : getMultiplexer(session.pane.mux);
      if (mux) await mux.closePane(session.pane).catch(() => {});
    }

    await session.adapter.kill();
    this.sessions.delete(id);
    // Drop any attach mapping so the underlying pi session can be re-attached.
    for (const [piId, sid] of this.attachedByPi) {
      if (sid === id) this.attachedByPi.delete(piId);
    }
  }
  /**
   * Open a session hosted by an external `makit-mirror` extension (World D):
   * events are pushed in via the returned IngestAdapter, and the phone's
   * prompts are relayed back through `onPrompt`. No process is spawned.
   */
  async openHostSession(opts: {
    title?: string;
    cwd?: string;
    projectId?: string;
    onPrompt: (text: string) => void;
    onAction?: (action: string, args?: Record<string, unknown>) => void;
  }): Promise<Session> {
    let project = opts.projectId ? this.projects.get(opts.projectId) : undefined;
    if (!project && opts.cwd) {
      project = [...this.projects.values()].find((p) => opts.cwd!.startsWith(p.dto.path));
    }
    if (!project) project = [...this.projects.values()][0];
    if (!project) throw new Error("no project for host session");

    const adapter = new IngestAdapter(opts.onPrompt, undefined, opts.onAction);
    // Wire up the real pi side-channel fetcher so the slash palette populates
    // with skills/prompts/extensions from the project's filesystem. ~1.2s
    // fire-and-forget at startup; failures are silenced (palette stays empty).
    adapter.enableCommands();
    const session = new Session({
      projectId: project.dto.id,
      agent: "pi",
      title: opts.title ?? DEFAULT_SESSION_TITLE,
      adapter,
    });
    await adapter.start({ cwd: project.dto.path });
    this.sessions.set(session.id, session);
    this.emit("sessionCreated", session);
    return session;
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
    // Wire up the real pi side-channel fetcher so the slash palette populates
    // with skills/prompts/extensions from the project's filesystem. ~1.2s
    // fire-and-forget at startup; failures are silenced (palette stays empty).
    adapter.enableCommands();
    const session = new Session({
      projectId: project.dto.id,
      agent: "pi",
      title: opts.title ?? DEFAULT_SESSION_TITLE,
      adapter,
    });
    await adapter.start({ cwd: project.dto.path });
    this.sessions.set(session.id, session);
    this.emit("sessionCreated", session);
    return session;
  }

  /** Construct the adapter for an agent id. */
  private buildAdapter(agentId: string): { agent: string; adapter: AgentAdapter } {
    switch (agentId) {
      case "pi-acp":
        return { agent: "pi-acp", adapter: new AcpAdapter({ spec: piAcpSpec() }) };
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
    });
    const activeAdapter = this.adapterFactory?.({
      projectPath: project.dto.path,
      sessionId: session.id,
      agent: agentId,
    }) ?? adapter;
    if (activeAdapter !== adapter) session.replaceAdapter(activeAdapter);

    // Seed history BEFORE the adapter goes live so it precedes new events.
    if (opts.backfill && opts.backfill.length > 0) session.backfill(opts.backfill);

    await activeAdapter.start({
      cwd: project.dto.path,
      sessionId: session.id,
      resumeSessionPath: opts.resumeSessionPath,
      model: this.defaultModel,
      env: this.bridge
        ? {
            MAKIT_BRIDGE_URL: this.bridge.url,
            MAKIT_BRIDGE_TOKEN: this.bridge.token,
            MAKIT_SESSION_ID: session.id,
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
      if (!hasOne) await this.spawnPiSession(p.dto.id, DEFAULT_SESSION_TITLE);
    }
  }

  /** All sessions (for fan-out on new connections). */
  allSessions(): Session[] {
    return [...this.sessions.values()];
  }
}
