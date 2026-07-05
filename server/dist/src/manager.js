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
import { PiAdapter } from "./adapters/pi.js";
import { MirrorAdapter } from "./adapters/mirror.js";
import { IngestAdapter } from "./adapters/ingest.js";
import { herdrReader, paneAgentInfo } from "./pane/herdr.js";
import { Session } from "./session.js";
import { listPiSessions, parseTranscript } from "./pi-sessions.js";
export class SessionManager extends EventEmitter {
    projects = new Map();
    sessions = new Map();
    /** pi session uuid → live pino session id, so re-attach reuses the process. */
    attachedByPi = new Map();
    /** In-flight attaches, so concurrent attach calls collapse onto one process. */
    attachInFlight = new Map();
    adapterFactory;
    onProjectsChanged;
    bridge;
    constructor(opts) {
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
    listProjects() {
        return [...this.projects.values()].map((p) => p.dto);
    }
    /**
     * Add a project by path. Resolves + dedupes by resolved path: if an existing
     * project already points at the same directory its DTO is returned unchanged
     * (no persist hook fired). Otherwise a new unpinned project is created and
     * the persist hook is notified.
     */
    addProject(path) {
        const resolved = resolve(path);
        const existing = [...this.projects.values()].find((p) => resolve(p.dto.path) === resolved);
        if (existing)
            return existing.dto;
        const id = randomUUID();
        const dto = {
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
    removeProject(id) {
        if (!this.projects.has(id))
            throw new Error(`unknown project: ${id}`);
        this.projects.delete(id);
        this.notifyProjectsChanged();
    }
    notifyProjectsChanged() {
        this.onProjectsChanged?.([...this.projects.values()].map((p) => p.dto.path));
    }
    listSessions() {
        return [...this.sessions.values()].map((s) => s.toDTO());
    }
    getSession(id) {
        return this.sessions.get(id);
    }
    /** Set the loopback bridge so subsequently-spawned pi sessions can use
     *  the pino-pi extension for AskUserQuestion round-trip. */
    setBridge(bridge) {
        this.bridge = bridge;
    }
    /** Spawn a fresh pi session inside `projectId`. */
    async spawnPiSession(projectId, title) {
        const project = this.projects.get(projectId);
        if (!project)
            throw new Error(`unknown project: ${projectId}`);
        return this.createSession(project, { title });
    }
    /** List a project's prior on-disk pi sessions (newest first). */
    listPiSessions(projectId) {
        const project = this.projects.get(projectId);
        if (!project)
            throw new Error(`unknown project: ${projectId}`);
        return listPiSessions(project.dto.path).map((m) => ({
            ...m,
            // A past session is "alive" when attached to a live pino session.
            attached: this.attachedByPi.has(m.piSessionId) &&
                this.sessions.has(this.attachedByPi.get(m.piSessionId)),
        }));
    }
    /**
     * Resume a prior on-disk pi session: backfill its full transcript into a new
     * pino session, then launch pi with `--session <path>` to continue it live.
     * Idempotent — attaching the same pi session twice returns the existing
     * pino session (never two pi processes on one file).
     */
    async attachPiSession(projectId, piSessionId) {
        const project = this.projects.get(projectId);
        if (!project)
            throw new Error(`unknown project: ${projectId}`);
        const existingId = this.attachedByPi.get(piSessionId);
        if (existingId) {
            const existing = this.sessions.get(existingId);
            if (existing)
                return existing;
            this.attachedByPi.delete(piSessionId);
        }
        // Collapse concurrent attaches of the same pi session onto one in-flight
        // promise so we never launch two pi processes against one transcript file.
        const pending = this.attachInFlight.get(piSessionId);
        if (pending)
            return pending;
        const task = (async () => {
            const meta = listPiSessions(project.dto.path).find((m) => m.piSessionId === piSessionId);
            if (!meta)
                throw new Error(`unknown pi session: ${piSessionId}`);
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
        }
        finally {
            this.attachInFlight.delete(piSessionId);
        }
    }
    /** Kill a session's agent process and drop it from the registry. */
    async killSession(id) {
        const session = this.sessions.get(id);
        if (!session)
            throw new Error(`no such session: ${id}`);
        await session.adapter.kill();
        this.sessions.delete(id);
        // Drop any attach mapping so the underlying pi session can be re-attached.
        for (const [piId, sid] of this.attachedByPi) {
            if (sid === id)
                this.attachedByPi.delete(piId);
        }
    }
    /**
     * Open a session hosted by an external `pino-mirror` extension (World D):
     * events are pushed in via the returned IngestAdapter, and the phone's
     * prompts are relayed back through `onPrompt`. No process is spawned.
     */
    async openHostSession(opts) {
        let project = opts.projectId ? this.projects.get(opts.projectId) : undefined;
        if (!project && opts.cwd) {
            project = [...this.projects.values()].find((p) => opts.cwd.startsWith(p.dto.path));
        }
        if (!project)
            project = [...this.projects.values()][0];
        if (!project)
            throw new Error("no project for host session");
        const adapter = new IngestAdapter(opts.onPrompt, undefined, opts.onAction);
        // Wire up the real pi side-channel fetcher so the slash palette populates
        // with skills/prompts/extensions from the project's filesystem. ~1.2s
        // fire-and-forget at startup; failures are silenced (palette stays empty).
        adapter.enableCommands();
        const session = new Session({
            projectId: project.dto.id,
            agent: "pi",
            title: opts.title ?? "pi (mirror)",
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
    async mirrorTuiSession(opts) {
        // Auto-discover the pane's agent session + cwd from herdr when not given.
        const info = !opts.sessionPath || !opts.projectId
            ? await paneAgentInfo(opts.paneTarget)
            : {};
        // Project: explicit id → match a project whose path contains the pane cwd
        // → first project.
        let project = opts.projectId ? this.projects.get(opts.projectId) : undefined;
        if (!project && info.cwd) {
            project = [...this.projects.values()].find((p) => info.cwd.startsWith(p.dto.path));
        }
        if (!project)
            project = [...this.projects.values()][0];
        if (!project)
            throw new Error("no project for mirror session");
        const sessionPath = opts.sessionPath ?? info.sessionPath ?? listPiSessions(project.dto.path)[0]?.path;
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
            title: opts.title ?? `TUI ${opts.paneTarget}`,
            adapter,
        });
        await adapter.start({ cwd: project.dto.path });
        this.sessions.set(session.id, session);
        this.emit("sessionCreated", session);
        return session;
    }
    /** Shared session construction for spawn + attach. */
    async createSession(project, opts) {
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
        if (activeAdapter !== adapter)
            session.replaceAdapter(activeAdapter);
        // Seed history BEFORE the adapter goes live so it precedes new events.
        if (opts.backfill && opts.backfill.length > 0)
            session.backfill(opts.backfill);
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
            if (!hasOne)
                await this.spawnPiSession(p.dto.id, "new session");
        }
    }
    /** All sessions (for fan-out on new connections). */
    allSessions() {
        return [...this.sessions.values()];
    }
}
//# sourceMappingURL=manager.js.map