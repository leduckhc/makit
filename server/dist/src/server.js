/**
 * WebSocket server with TLS + auth — thin wiring over four collaborators:
 *
 *   - {@link AuthGate}         — the `hello` handshake + auth decision.
 *   - {@link SubscriptionHub}  — `sub`/`unsub` + session-event fan-out.
 *   - {@link CommandRouter}    — OCP registry for `cmd` frames.
 *   - {@link ReverseRpc}       — `srv.request`/`srv.response` (askDevice).
 *
 * Auth model:
 *   - First frame on every connection must be a `hello`.
 *   - hello.bearer → long-lived paired-device token; if it matches a known
 *     device, we're authenticated.
 *   - hello.pair   → short-lived QR pair token; on success the server mints a
 *     new device and returns its bearer in `hello.ack.bearer`.
 *   - Anything else → close with 4401 (unauthorized).
 *
 * Localhost connections (loopback remote address) can opt out of auth via
 * `--no-auth` — useful for the `flutter run -d macos` dev loop. By default
 * even localhost is gated so behaviour matches production.
 *
 * All incoming frames are validated through the wire codec (`decodeFrame`);
 * malformed input yields an `err {code: bad_request}` and is never thrown.
 */
import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { createServer as createHttpsServer } from "node:https";
import { WebSocketServer } from "ws";
import { PROTOCOL_VERSION, newId } from "./protocol.js";
import { decodeFrame, encodeFrame, WireErrorCode } from "./protocol/codec.js";
import { log } from "./log.js";
import { browseDirectory } from "./project-store.js";
import { AuthGate } from "./ws/auth_gate.js";
import { SubscriptionHub } from "./ws/subscription_hub.js";
import { CommandRouter } from "./ws/command_router.js";
import { PaneBridge } from "./pane/bridge.js";
import { herdrReader } from "./pane/herdr.js";
import { ReverseRpc } from "./ws/reverse_rpc.js";
/**
 * Build the `host.ask.result` frame relayed to a pino-mirror extension after
 * the phone answers. Carries ONLY the answer fields — never spread the whole
 * srv.response envelope, whose own `t`/`id` would clobber these and leave the
 * extension's ask promise unresolved (hanging both the pi TUI and the phone).
 */
export function hostAskResultFrame(askId, resp) {
    return {
        t: "host.ask.result",
        id: askId,
        indices: resp.indices,
        answers: resp.answers,
        answer: resp.answer,
        cancelled: resp.cancelled,
    };
}
export function startWsServer(opts) {
    const { host, port, manager, cert, registry, trustLocalhost = false, hostToken } = opts;
    const https = createHttpsServer({ cert: cert.cert, key: cert.key });
    const wss = new WebSocketServer({ server: https });
    https.on("tlsClientError", (err, sock) => {
        log.warn(`[pino] TLS client error from ${sock.remoteAddress ?? "?"}: ${err.message}`);
    });
    wss.on("error", (err) => {
        log.error(`[pino] wss error: ${err.message}`);
    });
    const clients = new Map();
    // World D host sessions: pinoSessionId → its IngestAdapter + owning client.
    const hostAdapters = new Map();
    const hostOwner = new Map();
    // -------- collaborators -------------------------------------------------
    const hub = new SubscriptionHub({ manager });
    const rpc = new ReverseRpc({ clients: () => clients.values() });
    const paneBridge = new PaneBridge(herdrReader, (target, data) => {
        for (const c of clients.values()) {
            if (c.authed && c.panes?.has(target)) {
                c.send({ t: "event", id: newId("pane"), kind: "pane.frame", target, data });
            }
        }
    });
    const authGate = new AuthGate({ registry, onAuthenticated: sendSnapshots, hostToken });
    const router = buildCommandRouter();
    // -------- session wiring ------------------------------------------------
    for (const s of manager.allSessions())
        wireSession(s);
    // Also wire any sessions created later (e.g. via ensureDefaultSessions which
    // runs after startWsServer, or via the session.spawn cmd handler).
    manager.on("sessionCreated", (s) => wireSession(s));
    // -------- connection lifecycle ------------------------------------------
    wss.on("connection", (ws, req) => {
        const remote = req.socket.remoteAddress ?? "";
        log.info(`[pino] ws connection from ${remote}`);
        const isLocal = remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
        const state = makeClient(ws, trustLocalhost && isLocal);
        clients.set(ws, state);
        hub.register(state);
        ws.on("message", (raw) => {
            const env = decodeFrame(raw.toString());
            if (!env) {
                state.send({ t: "err", id: "", code: WireErrorCode.BadRequest, message: "malformed frame" });
                return;
            }
            handleEnvelope(state, env);
        });
        ws.on("close", () => {
            clients.delete(ws);
            hub.unregister(state);
            for (const t of state.panes ?? [])
                paneBridge.detach(t);
            // Tear down any host sessions owned by this extension client.
            for (const [sid, owner] of hostOwner) {
                if (owner === state) {
                    void manager.killSession(sid).catch(() => { });
                    hostAdapters.delete(sid);
                    hostOwner.delete(sid);
                }
            }
            broadcastSnapshots();
        });
        if (state.authed)
            sendSnapshots(state);
    });
    https.listen(port, host, () => {
        log.info(`[pino] wss listening on wss://${host}:${port}`);
    });
    const askDevice = rpc.askDevice.bind(rpc);
    // Device ids with a live authenticated WS connection — feeds the control
    // plane's `devices.list` "connected" flag (SPEC-01).
    const connectedDeviceIds = () => {
        const ids = new Set();
        for (const c of clients.values())
            if (c.authed && c.deviceId)
                ids.add(c.deviceId);
        return ids;
    };
    return { wss, https, askDevice, connectedDeviceIds };
    // -------- dispatch ------------------------------------------------------
    function handleEnvelope(state, env) {
        // The only thing an unauthed client may send is `hello`.
        if (!state.authed && env.t !== "hello") {
            state.send({ t: "err", id: env.id, code: WireErrorCode.Unauthorized, message: "unauthorized" });
            state.ws.close(4401, "unauthorized");
            return;
        }
        switch (env.t) {
            case "hello":
                authGate.handleHello(state, env);
                return;
            case "sub":
                hub.handleSub(state, env);
                return;
            case "unsub":
                hub.handleUnsub(state, env);
                return;
            case "cmd":
                void router.dispatch(state, env);
                return;
            case "ping":
                state.send({ t: "pong", id: env.id, ts: env.ts });
                return;
            case "srv.response":
                rpc.handleResponse(env);
                return;
            default:
                return;
        }
    }
    // -------- command handlers (OCP registry) -------------------------------
    function buildCommandRouter() {
        const r = new CommandRouter();
        r.register("send.message", async (ctx) => {
            const sid = String(ctx.env.sessionId ?? "");
            const text = ctx.env.text;
            if (typeof text !== "string") {
                ctx.err(WireErrorCode.BadRequest, "send.message requires a string `text`");
                return;
            }
            const session = sid ? manager.getSession(sid) : undefined;
            log.info(`[pino] send.message sid=${sid.slice(0, 8)} session=${!!session} text="${text.slice(0, 40)}"`);
            if (!session) {
                ctx.err(WireErrorCode.NoSuchSession, "no such session");
                return;
            }
            ctx.ack();
            await session.sendUserMessage(text);
        });
        // Built-in control actions (e.g. /compact, /thinking) — NOT user turns.
        // Routed to the adapter's sendAction, which relays to the hosting pi
        // extension's SDK calls. Only IngestAdapter (World D) maps these today.
        r.register("session.action", async (ctx) => {
            const sid = String(ctx.env.sessionId ?? "");
            const action = ctx.env.action;
            if (typeof action !== "string" || !action) {
                ctx.err(WireErrorCode.BadRequest, "session.action requires a string `action`");
                return;
            }
            const session = sid ? manager.getSession(sid) : undefined;
            if (!session) {
                ctx.err(WireErrorCode.NoSuchSession, "no such session");
                return;
            }
            const args = ctx.env.args && typeof ctx.env.args === "object" && !Array.isArray(ctx.env.args)
                ? ctx.env.args
                : undefined;
            ctx.ack();
            await session.sendAction(action, args);
        });
        r.register("cancel", async (ctx) => {
            const sid = String(ctx.env.sessionId ?? "");
            const session = sid ? manager.getSession(sid) : undefined;
            if (!session) {
                ctx.err(WireErrorCode.NoSuchSession, "no such session");
                return;
            }
            await session.adapter.cancel();
            ctx.ack();
        });
        r.register("session.kill", async (ctx) => {
            const sid = String(ctx.env.sessionId ?? "");
            try {
                await manager.killSession(sid);
            }
            catch {
                ctx.err(WireErrorCode.NoSuchSession, "no such session");
                return;
            }
            broadcastSnapshots();
            ctx.ack();
        });
        r.register("session.spawn", async (ctx) => {
            const projectId = String(ctx.env.projectId ?? "");
            const title = ctx.env.title ? String(ctx.env.title) : undefined;
            const newSession = await manager.spawnPiSession(projectId, title);
            // wireSession is invoked via the manager's "sessionCreated" listener
            // registered above — don't call it explicitly or every event fans out
            // twice.
            broadcastSnapshots();
            ctx.ack({ sessionId: newSession.id });
        });
        r.register("session.list", async (ctx) => {
            const projectId = String(ctx.env.projectId ?? "");
            if (!projectId) {
                ctx.err(WireErrorCode.BadRequest, "session.list requires a projectId");
                return;
            }
            try {
                // Omit the server-internal filesystem `path` from the wire — the app
                // attaches by piSessionId and never needs the transcript path.
                const sessions = manager.listPiSessions(projectId).map(({ path: _path, ...meta }) => meta);
                ctx.ack({ sessions });
            }
            catch (e) {
                ctx.err(WireErrorCode.BadRequest, e.message);
            }
        });
        r.register("session.attach", async (ctx) => {
            const projectId = String(ctx.env.projectId ?? "");
            const piSessionId = String(ctx.env.piSessionId ?? "");
            if (!projectId || !piSessionId) {
                ctx.err(WireErrorCode.BadRequest, "session.attach requires projectId and piSessionId");
                return;
            }
            try {
                const session = await manager.attachPiSession(projectId, piSessionId);
                broadcastSnapshots();
                ctx.ack({ sessionId: session.id });
            }
            catch (e) {
                ctx.err(WireErrorCode.BadRequest, e.message);
            }
        });
        r.register("project.browse", async (ctx) => {
            const raw = ctx.env.path;
            const path = typeof raw === "string" && raw.length > 0 ? raw : homedir();
            try {
                ctx.ack({ ...browseDirectory(path) });
            }
            catch (e) {
                ctx.err(WireErrorCode.BadRequest, e.message);
            }
        });
        r.register("project.add", async (ctx) => {
            const path = typeof ctx.env.path === "string" ? ctx.env.path : "";
            if (!path) {
                ctx.err(WireErrorCode.BadRequest, "project.add requires a string `path`");
                return;
            }
            const full = resolve(path);
            if (!existsSync(full) || !statSync(full).isDirectory()) {
                ctx.err(WireErrorCode.BadRequest, `not a directory: ${full}`);
                return;
            }
            const project = manager.addProject(full);
            broadcastSnapshots();
            ctx.ack({ projectId: project.id });
        });
        r.register("project.remove", async (ctx) => {
            const projectId = typeof ctx.env.projectId === "string" ? ctx.env.projectId : "";
            if (!projectId) {
                ctx.err(WireErrorCode.BadRequest, "project.remove requires a string `projectId`");
                return;
            }
            try {
                manager.removeProject(projectId);
            }
            catch (e) {
                ctx.err(WireErrorCode.BadRequest, e.message);
                return;
            }
            broadcastSnapshots();
            ctx.ack({});
        });
        // Pane bridge (POC): mirror a herdr/tmux pane running a real pi TUI.
        r.register("pane.attach", (ctx) => {
            const target = typeof ctx.env.target === "string" ? ctx.env.target : "";
            if (!target) {
                ctx.err(WireErrorCode.BadRequest, "pane.attach requires a string `target`");
                return;
            }
            (ctx.client.panes ??= new Set()).add(target);
            paneBridge.attach(target);
            ctx.ack();
        });
        r.register("pane.detach", (ctx) => {
            const target = typeof ctx.env.target === "string" ? ctx.env.target : "";
            if (target && ctx.client.panes?.delete(target))
                paneBridge.detach(target);
            ctx.ack();
        });
        r.register("pane.input", async (ctx) => {
            const target = typeof ctx.env.target === "string" ? ctx.env.target : "";
            const text = typeof ctx.env.text === "string" ? ctx.env.text : "";
            if (!target) {
                ctx.err(WireErrorCode.BadRequest, "pane.input requires a string `target`");
                return;
            }
            await paneBridge.input(target, text);
            ctx.ack();
        });
        r.register("pane.key", async (ctx) => {
            const target = typeof ctx.env.target === "string" ? ctx.env.target : "";
            const keys = Array.isArray(ctx.env.keys) ? ctx.env.keys.map(String) : [];
            if (!target) {
                ctx.err(WireErrorCode.BadRequest, "pane.key requires a string `target`");
                return;
            }
            await paneBridge.keys(target, keys);
            ctx.ack();
        });
        r.register("session.mirror", async (ctx) => {
            const pane = typeof ctx.env.pane === "string" ? ctx.env.pane : "";
            if (!pane) {
                ctx.err(WireErrorCode.BadRequest, "session.mirror requires a string `pane`");
                return;
            }
            const sessionPath = typeof ctx.env.sessionPath === "string" ? ctx.env.sessionPath : undefined;
            const projectId = typeof ctx.env.projectId === "string" ? ctx.env.projectId : undefined;
            const session = await manager.mirrorTuiSession({ paneTarget: pane, sessionPath, projectId });
            broadcastSnapshots();
            ctx.ack({ sessionId: session.id });
        });
        // World D: a pino-mirror extension hosts a real pi session and pushes its
        // events here; the phone's prompts are relayed back as `host.prompt`.
        r.register("host.open", async (ctx) => {
            const title = typeof ctx.env.title === "string" ? ctx.env.title : undefined;
            const cwd = typeof ctx.env.cwd === "string" ? ctx.env.cwd : undefined;
            const projectId = typeof ctx.env.projectId === "string" ? ctx.env.projectId : undefined;
            const owner = ctx.client;
            let sid = "";
            const session = await manager.openHostSession({
                title,
                cwd,
                projectId,
                onPrompt: (text) => owner.send({ t: "host.prompt", id: newId("hp"), sessionId: sid, text }),
                onAction: (action, args) => owner.send({ t: "host.action", id: newId("ha"), sessionId: sid, action, args }),
            });
            sid = session.id;
            hostAdapters.set(sid, session.adapter);
            hostOwner.set(sid, owner);
            broadcastSnapshots();
            ctx.ack({ sessionId: sid });
        });
        r.register("host.event", (ctx) => {
            const sid = typeof ctx.env.sessionId === "string" ? ctx.env.sessionId : "";
            const ev = ctx.env.ev;
            if (sid && ev)
                hostAdapters.get(sid)?.ingestEvent(ev);
            // No ack: events are high-frequency (streaming deltas).
        });
        r.register("host.status", (ctx) => {
            const sid = typeof ctx.env.sessionId === "string" ? ctx.env.sessionId : "";
            const status = ctx.env.status === "running" ? "running" : "idle";
            if (sid)
                hostAdapters.get(sid)?.ingestStatus(status);
        });
        // Update a host session's title after host.open (e.g. the extension only
        // learned the real session name once a pi event ran, or the user renamed
        // it). Re-broadcasts the sessions snapshot so the phone's list updates.
        r.register("host.retitle", (ctx) => {
            const sid = typeof ctx.env.sessionId === "string" ? ctx.env.sessionId : "";
            const title = typeof ctx.env.title === "string" ? ctx.env.title.trim() : "";
            const session = sid ? manager.getSession(sid) : undefined;
            if (session && title && session.title !== title) {
                session.title = title;
                broadcastSessionsSnapshot();
            }
        });
        r.register("host.close", async (ctx) => {
            const sid = typeof ctx.env.sessionId === "string" ? ctx.env.sessionId : "";
            if (sid) {
                await manager.killSession(sid).catch(() => { });
                hostAdapters.delete(sid);
                hostOwner.delete(sid);
                broadcastSnapshots();
            }
            ctx.ack();
        });
        r.register("host.ask", async (ctx) => {
            const sid = typeof ctx.env.sessionId === "string" ? ctx.env.sessionId : "";
            const askId = typeof ctx.env.askId === "string" ? ctx.env.askId : "";
            const questions = ctx.env.questions;
            const owner = ctx.client;
            try {
                // Route to the phone(s) subscribed to this mirror session; first wins.
                const resp = (await rpc.askDevice({ kind: "askUserQuestion", questions }, { sessionId: sid }));
                owner.send(hostAskResultFrame(askId, resp));
            }
            catch {
                owner.send({ t: "host.ask.result", id: askId, cancelled: true });
            }
        });
        // B9b: dev-only debug commands, registered only when PINO_DEV is set.
        if (process.env.PINO_DEV)
            registerDebugCommands(r);
        return r;
    }
    function registerDebugCommands(r) {
        r.register("debug.ask", async (ctx) => {
            ctx.ack();
            const resp = await askDevice({
                kind: "askUserQuestion",
                questions: [
                    {
                        header: "Test",
                        question: String(ctx.env.question ?? "Pick one"),
                        options: [
                            { label: "Yes" },
                            { label: "No" },
                            { label: "Maybe", description: "If you must" },
                        ],
                    },
                ],
            });
            log.info(`[pino] debug.ask answered: ${JSON.stringify(resp)}`);
        });
        r.register("debug.ask-multi", async (ctx) => {
            const sid = String(ctx.env.sessionId ?? "");
            const session = sid ? manager.getSession(sid) : undefined;
            if (!session) {
                ctx.err(WireErrorCode.NoSuchSession, "no such session");
                return;
            }
            ctx.ack();
            const resp = await askDevice({
                kind: "askUserQuestion",
                questions: [
                    {
                        header: "Language",
                        question: "Which language?",
                        options: [{ label: "Dart" }, { label: "TypeScript" }],
                        recommended: 0,
                    },
                    {
                        header: "Tools",
                        question: "Which tools?",
                        multi: true,
                        options: [{ label: "Simulator" }, { label: "Server" }, { label: "Logs" }],
                    },
                ],
            }, { sessionId: sid });
            log.info(`[pino] debug.ask-multi answered: ${JSON.stringify(resp)}`);
            session.adapter.emit("event", {
                ts: Date.now(),
                kind: "agent.message",
                payload: { text: JSON.stringify(resp) },
            });
        });
    }
    // -------- session fan-out + snapshots -----------------------------------
    function wireSession(session) {
        session.on("event", (event) => {
            const sent = hub.fanout(session.id, event);
            log.debug(`[pino] session.event sid=${session.id.slice(0, 8)} kind=${event.kind} → ${sent} subscriber(s)`);
            broadcastSessionsSnapshot();
        });
    }
    function sendSnapshots(client) {
        client.send({ t: "event", id: newId("snap"), kind: "projects.snapshot", projects: manager.listProjects() });
        client.send({ t: "event", id: newId("snap"), kind: "sessions.snapshot", sessions: manager.listSessions() });
    }
    function broadcastSnapshots() {
        for (const c of clients.values())
            if (c.authed)
                sendSnapshots(c);
    }
    function broadcastSessionsSnapshot() {
        const frame = {
            t: "event",
            id: newId("snap"),
            kind: "sessions.snapshot",
            sessions: manager.listSessions(),
        };
        for (const c of clients.values())
            if (c.authed)
                c.send(frame);
    }
    // -------- concrete client ------------------------------------------------
    function makeClient(ws, authed) {
        return {
            ws,
            authed,
            subscribed: new Set(),
            panes: new Set(),
            send(frame) {
                if (ws.readyState !== ws.OPEN)
                    return;
                ws.send(encodeFrame({ v: PROTOCOL_VERSION, ...frame }));
            },
            close(code, reason) {
                ws.close(code, reason);
            },
        };
    }
}
//# sourceMappingURL=server.js.map