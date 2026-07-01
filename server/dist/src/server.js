/**
 * WebSocket server with TLS + auth.
 *
 * Auth model:
 *   - First frame on every connection must be a `hello`.
 *   - hello.body.bearer → long-lived paired-device token; if it matches a
 *     known device, we're authenticated.
 *   - hello.body.pair   → short-lived QR pair token; on success the server
 *     mints a new device and returns its bearer in `hello.ack.bearer`.
 *   - Anything else → close with 4401 (unauthorized).
 *
 * Localhost connections (loopback remote address) can opt out of auth via
 * `--no-auth` — useful for the `flutter run -d macos` dev loop. By default
 * even localhost is gated so behaviour matches production.
 */
import { createServer as createHttpsServer } from "node:https";
import { WebSocketServer } from "ws";
import { PROTOCOL_VERSION, newId } from "./protocol.js";
export function startWsServer(opts) {
    const { host, port, manager, cert, registry, trustLocalhost = false } = opts;
    const https = createHttpsServer({ cert: cert.cert, key: cert.key });
    const wss = new WebSocketServer({ server: https });
    https.on("tlsClientError", (err, sock) => {
        console.log(`[pino] TLS client error from ${sock.remoteAddress ?? "?"}: ${err.message}`);
    });
    wss.on("error", (err) => {
        console.log(`[pino] wss error: ${err.message}`);
    });
    const clients = new Map();
    const pendingRequests = new Map();
    let reqCounter = 0;
    for (const s of manager.allSessions())
        wireSession(s);
    // Also wire any sessions created later (e.g. via ensureDefaultSessions
    // which runs after startWsServer, or via the session.new cmd handler).
    manager.on("sessionCreated", (s) => wireSession(s));
    wss.on("connection", (ws, req) => {
        const remote = req.socket.remoteAddress ?? "";
        console.log(`[pino] ws connection from ${remote}`);
        const isLocal = remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
        const state = {
            ws,
            subscribed: new Set(),
            authed: trustLocalhost && isLocal,
        };
        clients.set(ws, state);
        ws.on("message", (raw) => {
            let env;
            try {
                env = JSON.parse(raw.toString());
            }
            catch {
                return;
            }
            handleEnvelope(state, env);
        });
        ws.on("close", () => {
            clients.delete(ws);
        });
        if (state.authed)
            sendSnapshots(state);
    });
    https.listen(port, host, () => {
        console.log(`[pino] wss listening on wss://${host}:${port}`);
    });
    return { wss, https, askDevice };
    // -------- handlers ------------------------------------------------------
    function handleEnvelope(state, env) {
        // The only thing an unauthed client may send is `hello`.
        if (!state.authed && env.t !== "hello") {
            sendErr(state, env.id, "unauthorized");
            state.ws.close(4401, "unauthorized");
            return;
        }
        switch (env.t) {
            case "hello":
                handleHello(state, env);
                return;
            case "sub": {
                const sid = String(env.sessionId ?? "");
                if (!sid) {
                    sendErr(state, env.id, "missing sessionId");
                    return;
                }
                const session = manager.getSession(sid);
                if (!session) {
                    sendErr(state, env.id, `no such session: ${sid}`);
                    return;
                }
                state.subscribed.add(sid);
                console.log(`[pino] sub: client subscribed to session ${sid.slice(0, 8)} (replay ${session.events.length} events)`);
                for (const e of session.events)
                    sendEvent(state, e);
                send(state, { t: "ack", id: env.id });
                return;
            }
            case "unsub": {
                const sid = String(env.sessionId ?? "");
                state.subscribed.delete(sid);
                send(state, { t: "ack", id: env.id });
                return;
            }
            case "cmd":
                void handleCmd(state, env);
                return;
            case "ping":
                send(state, { t: "pong", id: env.id, ts: env.ts });
                return;
            case "srv.response": {
                const pending = pendingRequests.get(env.id);
                if (pending) {
                    pendingRequests.delete(env.id);
                    pending.resolve(env);
                }
                return;
            }
            default:
                return;
        }
    }
    function handleHello(state, env) {
        const bearer = typeof env.bearer === "string" ? env.bearer : "";
        const pair = typeof env.pair === "string" ? env.pair : "";
        const label = typeof env.label === "string" ? env.label : "device";
        if (bearer) {
            const device = registry.authenticate(bearer);
            if (!device) {
                console.log(`[pino] hello: unknown bearer (rejected)`);
                sendErr(state, env.id, "unknown device");
                state.ws.close(4401, "unauthorized");
                return;
            }
            state.authed = true;
            state.deviceLabel = device.label;
            send(state, { t: "hello.ack", id: env.id, ok: true, deviceId: device.id });
            console.log(`[pino] hello: authed as ${device.label} (${device.id}); sent snapshots`);
            sendSnapshots(state);
            return;
        }
        if (pair) {
            const device = registry.consumePairToken(pair, label);
            if (!device) {
                sendErr(state, env.id, "invalid or expired pairing token");
                state.ws.close(4401, "unauthorized");
                return;
            }
            state.authed = true;
            state.deviceLabel = device.label;
            console.log(`[pino] paired new device: ${device.label} (${device.id})`);
            send(state, {
                t: "hello.ack",
                id: env.id,
                ok: true,
                deviceId: device.id,
                bearer: device.bearer,
            });
            sendSnapshots(state);
            return;
        }
        if (state.authed) {
            // Already trusted (localhost dev mode).
            send(state, { t: "hello.ack", id: env.id, ok: true });
            sendSnapshots(state);
            return;
        }
        sendErr(state, env.id, "missing bearer or pair token");
        state.ws.close(4401, "unauthorized");
    }
    async function handleCmd(state, env) {
        const kind = String(env.kind ?? "");
        const sid = String(env.sessionId ?? "");
        const session = sid ? manager.getSession(sid) : undefined;
        try {
            switch (kind) {
                case "send.message": {
                    console.log(`[pino] send.message sid=${sid.slice(0, 8)} session=${!!session} text="${String(env.text ?? "").slice(0, 40)}"`);
                    if (!session) {
                        sendErr(state, env.id, "no such session");
                        return;
                    }
                    send(state, { t: "ack", id: env.id });
                    await session.sendUserMessage(String(env.text ?? ""));
                    return;
                }
                case "cancel": {
                    if (!session) {
                        sendErr(state, env.id, "no such session");
                        return;
                    }
                    await session.adapter.cancel();
                    send(state, { t: "ack", id: env.id });
                    return;
                }
                case "session.spawn": {
                    const projectId = String(env.projectId ?? "");
                    const title = env.title ? String(env.title) : undefined;
                    const newSession = await manager.spawnPiSession(projectId, title);
                    // wireSession is invoked via the manager's "sessionCreated" listener
                    // registered above — don't call it explicitly or every event fans
                    // out twice.
                    broadcastSnapshots();
                    send(state, { t: "ack", id: env.id, sessionId: newSession.id });
                    return;
                }
                case "debug.ask": {
                    send(state, { t: "ack", id: env.id });
                    const resp = await askDevice({
                        kind: "askUserQuestion",
                        questions: [
                            {
                                header: "Test",
                                question: String(env.question ?? "Pick one"),
                                options: [
                                    { label: "Yes" },
                                    { label: "No" },
                                    { label: "Maybe", description: "If you must" },
                                ],
                            },
                        ],
                    });
                    console.log(`[pino] debug.ask answered: ${JSON.stringify(resp)}`);
                    return;
                }
                case "debug.ask-multi": {
                    if (!session) {
                        sendErr(state, env.id, "no such session");
                        return;
                    }
                    send(state, { t: "ack", id: env.id });
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
                    console.log(`[pino] debug.ask-multi answered: ${JSON.stringify(resp)}`);
                    session.adapter.emit("event", {
                        ts: Date.now(),
                        kind: "agent.message",
                        payload: { text: JSON.stringify(resp) },
                    });
                    return;
                }
                default:
                    sendErr(state, env.id, `unknown cmd: ${kind}`);
            }
        }
        catch (e) {
            sendErr(state, env.id, e.message);
        }
    }
    function wireSession(session) {
        session.on("event", (event) => {
            let sent = 0;
            for (const c of clients.values()) {
                if (c.authed && c.subscribed.has(session.id)) {
                    sendEvent(c, event);
                    sent++;
                }
            }
            console.log(`[pino] session.event sid=${session.id.slice(0, 8)} kind=${event.kind} → ${sent} subscriber(s)`);
            broadcastSessionsSnapshot();
        });
    }
    function sendSnapshots(state) {
        send(state, { t: "event", id: newId("snap"), kind: "projects.snapshot", projects: manager.listProjects() });
        send(state, { t: "event", id: newId("snap"), kind: "sessions.snapshot", sessions: manager.listSessions() });
    }
    function broadcastSnapshots() {
        for (const c of clients.values())
            if (c.authed)
                sendSnapshots(c);
    }
    function broadcastSessionsSnapshot() {
        const env = {
            t: "event",
            id: newId("snap"),
            kind: "sessions.snapshot",
            sessions: manager.listSessions(),
        };
        for (const c of clients.values())
            if (c.authed)
                send(c, env);
    }
    function sendEvent(state, event) {
        send(state, { t: "event", id: newId("ev"), kind: "session.event", event });
    }
    /// Ask any authed client (typically the user's phone) something and wait
    /// for an `srv.response`. Used by server-side tool implementations that
    /// need user input (e.g. AskUserQuestion).
    ///
    /// Sends `srv.request` to every subscribed client of [sessionId] (or all
    /// authed clients if no sessionId is given). The first response wins.
    function askDevice(body, opts = {}) {
        const id = `srv-${Date.now()}-${++reqCounter}`;
        const timeoutMs = opts.timeoutMs ?? 5 * 60 * 1000; // 5 min default
        const envelope = { t: "srv.request", id, ...body, ...(opts.sessionId ? { sessionId: opts.sessionId } : {}) };
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                pendingRequests.delete(id);
                reject(new Error(`srv.request timed out after ${timeoutMs}ms`));
            }, timeoutMs);
            pendingRequests.set(id, { resolve, timer });
            let sent = 0;
            for (const c of clients.values()) {
                if (!c.authed)
                    continue;
                if (opts.sessionId && !c.subscribed.has(opts.sessionId))
                    continue;
                send(c, envelope);
                sent++;
            }
            if (sent === 0) {
                clearTimeout(timer);
                pendingRequests.delete(id);
                reject(new Error("no subscribed clients to ask"));
            }
        }).finally(() => {
            const p = pendingRequests.get(id);
            if (p) {
                clearTimeout(p.timer);
                pendingRequests.delete(id);
            }
        });
    }
    function send(state, body) {
        if (state.ws.readyState !== state.ws.OPEN)
            return;
        state.ws.send(JSON.stringify({ v: PROTOCOL_VERSION, ...body }));
    }
    function sendErr(state, id, message) {
        send(state, { t: "err", id, message });
    }
}
//# sourceMappingURL=server.js.map