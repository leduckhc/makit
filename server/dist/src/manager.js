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
import { PiAdapter } from "./adapters/pi.js";
import { Session } from "./session.js";
export class SessionManager extends EventEmitter {
    projects = new Map();
    sessions = new Map();
    adapterFactory;
    bridge;
    constructor(opts) {
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
    listProjects() {
        return [...this.projects.values()].map((p) => p.dto);
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
        // Create the session first so we have an id to thread into the bridge.
        const adapter = new PiAdapter();
        const session = new Session({
            projectId,
            agent: this.adapterFactory ? "stub" : "pi",
            title: title ?? (this.adapterFactory ? "stub session" : "pi session"),
            adapter,
        });
        const activeAdapter = this.adapterFactory?.({
            projectPath: project.dto.path,
            sessionId: session.id,
        }) ?? adapter;
        if (activeAdapter !== adapter)
            session.replaceAdapter(activeAdapter);
        await activeAdapter.start({
            cwd: project.dto.path,
            sessionId: session.id,
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