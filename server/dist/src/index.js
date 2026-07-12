#!/usr/bin/env node
/**
 * makit — desktop server CLI.
 *
 * Usage:
 *   makit serve [--host H] [--lan] [--port 8787] [--project P]... [--no-auth]
 *   makit pair  [--host H] [--port P]                  # prints a QR + URL
 *
 * Default host (secure by default): Tailscale IP if online, else loopback
 * only. makit does NOT expose the local network by default — on public Wi-Fi
 * that would leave the port reachable by untrusted co-tenants. Pass `--lan`
 * to opt into binding the LAN IPv4 (trusted networks only), or `--host
 * 0.0.0.0` to bind every interface. The recommended transport is Tailscale.
 * A loopback listener is added automatically when host is a specific IP,
 * so the makit-mirror extension host and the flutter dev loop keep working.
 *
 * `makit serve` is the long-running server. `makit pair` is meant to be run
 * from a second terminal (or as a hotkey on an already-running server) to
 * mint a fresh pairing token. For M1 we co-locate both — `makit pair`
 * connects to the running server over a unix socket would be cleaner; for
 * now `makit serve` accepts a SIGUSR1 to print a new QR, and `makit pair`
 * works only if the user runs it as a one-shot _instead of_ `serve`.
 *
 * Simplest current UX: at startup, `makit serve` automatically prints one
 * QR with a fresh pair token. The user scans it; subsequent connects use
 * the persistent bearer.
 */
import { resolve } from "node:path";
import qrcode from "qrcode-terminal";
import { SessionManager } from "./manager.js";
import { projectsFile, loadProjectPaths, saveProjectPaths } from "./project-store.js";
import { buildFilteredAgentDir } from "./pi-agent-dir.js";
import { startWsServer } from "./server.js";
import { loadApnsConfig, createPushSender } from "./push/config.js";
import { buildWakePayload } from "./push/payload.js";
import { startBridge } from "./bridge.js";
import { fileURLToPath } from "node:url";
import { dirname, resolve as resolvePath } from "node:path";
import { loadOrCreateCert, chooseBindHost } from "./pairing/cert.js";
import { DeviceRegistry } from "./pairing/registry.js";
import { buildPairUrl } from "./pairing/url.js";
import { MdnsAd } from "./pairing/mdns.js";
import { randomBytes } from "node:crypto";
import { writeFileSync, mkdirSync, symlinkSync, existsSync, rmSync, readFileSync, openSync } from "node:fs";
import { homedir } from "node:os";
import { spawn as childSpawn } from "node:child_process";
import { createServerBackend } from "./daemon/backend.js";
import { createControlServer } from "./daemon/control-server.js";
import { createDaemon, readPidFile } from "./daemon/service.js";
import { connectControlClient } from "./daemon/control-client.js";
import { controlSocketPath, pidFilePath, logFilePath, ensureMakitHome } from "./daemon/paths.js";
import { installService, uninstallService } from "./daemon/launchd.js";
/** makit version, read from package.json (best-effort). */
const MAKIT_VERSION = (() => {
    try {
        const pkg = resolvePath(dirname(fileURLToPath(import.meta.url)), "../package.json");
        return JSON.parse(readFileSync(pkg, "utf8")).version ?? "0.0.0";
    }
    catch {
        return "0.0.0";
    }
})();
/** Build a Daemon wired to real OS primitives (spawn/kill/control socket). */
function makeDaemon() {
    return createDaemon({
        entry: fileURLToPath(import.meta.url),
        execPath: process.execPath,
        socketPath: controlSocketPath(),
        pidPath: pidFilePath(),
        logPath: logFilePath(),
        out: (line) => console.log(line),
        spawn: (cmd, args, logFd) => {
            // Forward the parent's node flags (e.g. tsx's `--require`/`--import`
            // loader, injected via execArgv, not NODE_OPTIONS) so the detached
            // daemon resolves TS-style `.js` imports the same way the CLI does.
            // Without this, plain node can't resolve imports like `./manager.js`.
            const child = childSpawn(cmd, [...process.execArgv, ...args], { detached: true, stdio: ["ignore", logFd, logFd] });
            return { pid: child.pid, unref: () => child.unref() };
        },
        openLogFd: (p) => {
            ensureMakitHome();
            return openSync(p, "w", 0o600);
        },
        kill: (pid, sig) => process.kill(pid, sig),
        isAlive: (pid) => {
            try {
                process.kill(pid, 0);
                return true;
            }
            catch {
                return false;
            }
        },
        connect: (sp) => connectControlClient(sp),
    });
}
function parseArgs(argv) {
    const args = {
        // "" means "auto": decide the bind host after parsing --host/--lan below,
        // secure-by-default (Tailscale > opt-in LAN > loopback).
        host: "",
        lan: false,
        port: 8787,
        projects: [],
        noAuth: false,
        printPair: true,
        advertise: process.env.MAKIT_ADVERTISE_HOST ?? "",
        bindMode: "loopback",
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === "--port")
            args.port = Number(argv[++i]);
        else if (a === "--host")
            args.host = String(argv[++i]);
        else if (a === "--lan")
            args.lan = true;
        else if (a === "--project" || a === "-C")
            args.projects.push(resolve(String(argv[++i])));
        else if (a === "--no-auth")
            args.noAuth = true;
        else if (a === "--no-pair-qr")
            args.printPair = false;
        else if (a === "--advertise")
            args.advertise = String(argv[++i]);
    }
    if (args.host) {
        // Explicit --host overrides the secure-by-default decision (escape hatch,
        // e.g. --host 0.0.0.0 for all interfaces).
        args.bindMode = "custom";
    }
    else {
        const decision = chooseBindHost({ allowLan: args.lan });
        args.host = decision.host;
        args.bindMode = decision.mode;
    }
    if (args.projects.length === 0)
        args.projects.push(process.cwd());
    return args;
}
/** Dedupe paths by their resolved absolute form, preserving first-seen order. */
function dedupeResolved(paths) {
    const seen = new Set();
    const out = [];
    for (const p of paths) {
        const key = resolve(p);
        if (seen.has(key))
            continue;
        seen.add(key);
        out.push(key);
    }
    return out;
}
async function main() {
    const cmd = process.argv[2];
    const LIFECYCLE = new Set(["start", "stop", "restart", "status", "logs", "service"]);
    const KNOWN = new Set(["serve", "pair", "qr", "devices", "sessions", "attach", "mirror", ...LIFECYCLE]);
    if (cmd && !KNOWN.has(cmd)) {
        console.error(`unknown command: ${cmd}\n` +
            `usage: makit serve|start|stop|restart|status|logs|service|pair|qr|devices|sessions|attach|mirror [...]`);
        process.exit(2);
    }
    if (cmd === "mirror") {
        const { runMirror } = await import("./cli/mirror.js");
        await runMirror(process.argv.slice(3));
        return;
    }
    // --- SPEC-02 thin-client subcommands: drive the running daemon via the
    // control socket. requireDaemon() handles "not running" uniformly. ---
    if (cmd === "qr" || cmd === "pair") {
        const { runQr } = await import("./cli/qr.js");
        // `makit pair` is an alias for `makit qr --refresh` (daemon required).
        const argv = cmd === "pair" ? ["--refresh", ...process.argv.slice(3)] : process.argv.slice(3);
        await runQr(argv);
        return;
    }
    if (cmd === "devices") {
        const { runDevices } = await import("./cli/devices.js");
        await runDevices(process.argv.slice(3));
        return;
    }
    if (cmd === "sessions") {
        const { runSessions } = await import("./cli/sessions.js");
        await runSessions(process.argv.slice(3));
        return;
    }
    // `attach` is a client, not a server: connect to a running makit and drive
    // one session from the terminal. No cert/registry/manager needed here.
    if (cmd === "attach") {
        const argv = process.argv.slice(3);
        if (argv.includes("--pane")) {
            const { runPaneAttach } = await import("./cli/attach-pane.js");
            await runPaneAttach(argv);
        }
        else {
            const { runAttach } = await import("./cli/attach.js");
            await runAttach(argv);
        }
        return;
    }
    // --- background service lifecycle (SPEC-01) — thin clients of the control
    // socket / process management. These do not need cert/manager. ---
    if (LIFECYCLE.has(cmd) && cmd !== "service") {
        const daemon = makeDaemon();
        const a = parseArgs(process.argv.slice(3));
        const serveOpts = {
            host: a.host,
            port: a.port,
            projects: a.projects,
            noAuth: a.noAuth,
            advertise: a.advertise,
        };
        let code = 0;
        if (cmd === "start")
            code = await daemon.start(serveOpts);
        else if (cmd === "stop")
            code = await daemon.stop();
        else if (cmd === "restart")
            code = await daemon.restart(serveOpts);
        else if (cmd === "status")
            code = await daemon.status();
        else if (cmd === "logs") {
            const rest = process.argv.slice(3);
            const follow = rest.includes("--follow") || rest.includes("-f");
            const li = rest.indexOf("--lines");
            const lines = li >= 0 ? Number(rest[li + 1]) : undefined;
            code = await daemon.logs({ follow, lines });
        }
        process.exit(code);
    }
    if (cmd === "service") {
        const sub = process.argv[3];
        const entry = fileURLToPath(import.meta.url);
        const plistPath = resolvePath(homedir(), "Library", "LaunchAgents", "dev.makit.plist");
        if (sub === "install") {
            installService({
                label: "dev.makit",
                execPath: process.execPath,
                entry,
                logPath: logFilePath(),
                plistPath,
            });
            console.log(`[makit] launchd agent installed: ${plistPath}`);
            console.log(`[makit] it does NOT auto-start. Load it with: launchctl load ${plistPath}`);
        }
        else if (sub === "uninstall") {
            const removed = uninstallService({ plistPath });
            console.log(removed ? `[makit] launchd agent removed: ${plistPath}` : `[makit] no launchd agent installed`);
        }
        else {
            console.error("usage: makit service install|uninstall");
            process.exit(2);
        }
        return;
    }
    const opts = parseArgs(process.argv.slice(3));
    const cert = await loadOrCreateCert();
    const registry = new DeviceRegistry();
    // Merge persisted projects with any CLI `--project` roots, deduping by
    // resolved path so a restart neither loses nor duplicates entries. Persist
    // the merged set once at startup so a fresh `--project` gets recorded.
    const file = projectsFile();
    const persisted = loadProjectPaths(file);
    const merged = dedupeResolved([...persisted, ...opts.projects]);
    saveProjectPaths(file, merged);
    const manager = new SessionManager({
        projects: merged,
        onProjectsChanged: (paths) => saveProjectPaths(file, paths),
    });
    // World D: a stable secret the makit-mirror pi extension uses to authenticate.
    // Written (0600) to ~/.makit/host.json so an externally-launched pi can find us.
    const hostToken = loadOrCreateHostToken();
    // SPEC-07: choose the content-free wake sender. Absent/invalid push.json →
    // NoopPushSender (graceful degradation: wakes are no-ops, Slice-1 fallback).
    // The WakeCoordinator + onUndeliverable wiring lives inside server.ts, which
    // owns `connectedDeviceIds`; index.ts only picks the sender and forwards it.
    const apnsConfig = loadApnsConfig();
    const sender = createPushSender(apnsConfig);
    if (!sender.enabled) {
        console.log("[makit] push: not configured (~/.makit/push.json absent/invalid) — wakes disabled");
    }
    const ws = startWsServer({
        host: opts.host,
        port: opts.port,
        manager,
        cert,
        registry,
        trustLocalhost: opts.noAuth,
        hostToken,
        sender,
        buildWakePayload,
    });
    writeHostFile(opts.port, cert.fingerprint, hostToken);
    ensureMirrorExtensionInstalled();
    // Loopback HTTP bridge so agent connectors (loaded inside each spawned
    // agent process) can talk back to makit.
    // The ws server's askDevice resolves with the srv.response envelope, which
    // is FLAT — the canonical UIResponse fields (kind, indices, answers, …) live
    // at the top level alongside v/t/id, not under a `.body`. Return it as-is.
    const bridge = await startBridge({
        askDevice: async (body) => {
            const { sessionId, ...rest } = body;
            const env = await ws.askDevice(rest, { sessionId });
            return env;
        },
    });
    // Auto-discover every `.ts` connector in `server/connectors/`. Each one
    // gets loaded into the spawned `pi --mode rpc` process via `-e`. To add
    // a new agent, drop a file there — no code changes needed in makit.
    const connectorsDir = resolvePath(dirname(fileURLToPath(import.meta.url)), "../connectors");
    const { readdirSync, existsSync } = await import("node:fs");
    const extensionPaths = existsSync(connectorsDir)
        ? readdirSync(connectorsDir)
            .filter((f) => f.endsWith(".ts"))
            .map((f) => resolvePath(connectorsDir, f))
        : [];
    if (extensionPaths.length === 0) {
        console.log("[makit] no agent connectors found in", connectorsDir);
    }
    else {
        console.log(`[makit] loading ${extensionPaths.length} connector(s):`, extensionPaths.map((p) => p.split("/").pop()).join(", "));
    }
    manager.setBridge({
        url: bridge.url,
        token: bridge.token,
        extensionPaths,
        // Same flat-envelope askDevice, reused by the PiAdapter UI interceptor.
        askUser: async (call) => {
            const { sessionId, ...rest } = call;
            const env = await ws.askDevice(rest, { sessionId });
            return env;
        },
        // Exclude TUI-only packages that can't run headless (see UI-TRANSPORT.md).
        agentDir: buildFilteredAgentDir(["@mammothb/pi-ask"]),
    });
    await manager.ensureDefaultSessions();
    const mdns = new MdnsAd();
    mdns.start({ port: opts.port, fingerprint: cert.fingerprint });
    // --- control plane (SPEC-01): let `makit status|stop|qr|devices|…` drive this
    // running server without a restart. Served by BOTH foreground `serve` and the
    // detached `makit start` process. ---
    ensureMakitHome(); // 0700 state dir before the control socket binds (perms race)
    const backend = createServerBackend({
        registry,
        manager,
        fingerprint: cert.fingerprint,
        host: opts.host,
        port: opts.port,
        advertiseHost: opts.advertise,
        version: MAKIT_VERSION,
        startedAt: Date.now(),
        now: () => Date.now(),
        connectedDeviceIds: ws.connectedDeviceIds,
        buildUrl: (token) => buildPairUrl({
            host: opts.advertise && opts.advertise.length > 0 ? opts.advertise : opts.host,
            port: opts.port,
            fingerprint: cert.fingerprint,
            token,
        }),
        requestStop: () => process.kill(process.pid, "SIGTERM"),
        logPath: logFilePath(),
    });
    let control;
    try {
        control = await createControlServer({ socketPath: controlSocketPath(), backend });
        console.log(`[makit] control socket: ${controlSocketPath()}`);
    }
    catch (e) {
        console.error(`[makit] control socket unavailable: ${e.message}`);
    }
    // Graceful shutdown: `makit stop` sends SIGTERM (as does the `server.stop`
    // control verb, via requestStop). Tear down the control socket, WS, and mDNS,
    // and remove our own PID file. Idempotent.
    let shuttingDown = false;
    const shutdown = () => {
        if (shuttingDown)
            return;
        shuttingDown = true;
        console.log("[makit] shutting down…");
        void control?.close().catch(() => { });
        try {
            mdns.stop();
        }
        catch { /* best-effort */ }
        try {
            ws.wss.close();
        }
        catch { /* best-effort */ }
        try {
            ws.https.close();
        }
        catch { /* best-effort */ }
        try {
            ws.localHttps?.close();
        }
        catch { /* best-effort */ }
        // Only clear the PID file if it points at us (a detached `start` wrote it).
        if (readPidFile(pidFilePath()) === process.pid)
            rmSync(pidFilePath(), { force: true });
        setTimeout(() => process.exit(0), 100).unref();
    };
    process.on("SIGTERM", shutdown);
    process.on("SIGINT", shutdown);
    console.log(`[makit] cert fingerprint: ${cert.fingerprint}`);
    console.log(`[makit] mDNS: advertising _makit._tcp on port ${opts.port}`);
    console.log(`[makit] projects:`);
    for (const p of manager.listProjects())
        console.log(`  · ${p.name}  (${p.path})`);
    printTransport(opts.bindMode, opts.host);
    // Auto-rotate pair tokens while no devices are paired, so a QR is always
    // valid on screen. Stops once the first device pairs.
    let rotateTimer;
    const maybeRotate = () => {
        if (registry.list().length === 0 && opts.printPair) {
            console.log("");
            console.log("[makit] no paired devices yet — scan this QR with the app:");
            printPairQr(registry, opts.port, cert.fingerprint, opts.advertise, opts.host);
            // Re-mint just before the 5-minute TTL expires.
            rotateTimer = setTimeout(maybeRotate, 4 * 60 * 1000);
        }
        else {
            console.log(`[makit] ${registry.list().length} paired device(s). Send SIGUSR1 to mint a new pair token.`);
        }
    };
    maybeRotate();
    // SIGUSR1 → print a fresh pair QR on demand. Handy without restarting.
    process.on("SIGUSR1", () => {
        clearTimeout(rotateTimer);
        printPairQr(registry, opts.port, cert.fingerprint, opts.advertise, opts.host);
        if (registry.list().length === 0) {
            rotateTimer = setTimeout(maybeRotate, 4 * 60 * 1000);
        }
    });
    if (opts.noAuth) {
        console.log("[makit] --no-auth: localhost connections bypass auth (dev only)");
        console.log(`[makit] dev: flutter run --dart-define=MAKIT_WS_URL=wss://127.0.0.1:${opts.port} --dart-define=MAKIT_FP=${cert.fingerprint}`);
    }
}
/**
 * Make `makit-mirror` auto-load into every `pi` by symlinking it (and its lone
 * runtime dep, `ws`) into pi's global extensions dir. Idempotent + best-effort,
 * so `makit serve` is all it takes for any `pi` to mirror while makit runs.
 */
function ensureMirrorExtensionInstalled() {
    try {
        const here = dirname(fileURLToPath(import.meta.url)); // server/src
        const extSrc = resolvePath(here, "../extensions/makit-mirror.ts");
        const wsPkg = resolvePath(here, "../node_modules/ws");
        if (!existsSync(extSrc) || !existsSync(wsPkg))
            return;
        const extDir = resolvePath(homedir(), ".pi", "agent", "extensions");
        mkdirSync(resolvePath(extDir, "node_modules"), { recursive: true });
        const relink = (target, linkPath) => {
            try {
                rmSync(linkPath, { force: true });
                symlinkSync(target, linkPath);
            }
            catch {
                /* best-effort */
            }
        };
        relink(extSrc, resolvePath(extDir, "makit-mirror.ts"));
        relink(wsPkg, resolvePath(extDir, "node_modules", "ws"));
        disableConflictingAskExtension();
        console.log("[makit] mirror extension installed — any `pi` auto-mirrors while makit runs.");
    }
    catch {
        /* non-fatal */
    }
    /**
     * Remove @mammothb/pi-ask from pi's settings if present. makit-mirror registers
     * the same `AskUserQuestion` tool (routed to the phone, with a TUI fallback),
     * and pi treats a duplicate tool name as a FATAL load error — so leaving pi-ask
     * enabled would stop pi from starting. Backed up once; re-enable any time with
     * `pi install npm:@mammothb/pi-ask`.
     */
    function disableConflictingAskExtension() {
        try {
            const settings = resolvePath(homedir(), ".pi", "agent", "settings.json");
            if (!existsSync(settings))
                return;
            const parsed = JSON.parse(readFileSync(settings, "utf8"));
            const pkgs = parsed.packages;
            if (!Array.isArray(pkgs))
                return;
            const kept = pkgs.filter((p) => typeof p !== "string" || !p.includes("pi-ask"));
            if (kept.length === pkgs.length)
                return; // pi-ask not present
            const bak = settings + ".bak";
            if (!existsSync(bak))
                writeFileSync(bak, JSON.stringify(parsed, null, 1));
            parsed.packages = kept;
            writeFileSync(settings, JSON.stringify(parsed, null, 1));
            console.log("[makit] disabled @mammothb/pi-ask (makit-mirror provides AskUserQuestion). Re-enable: pi install npm:@mammothb/pi-ask");
        }
        catch {
            /* non-fatal */
        }
    }
}
/**
 * Reuse the existing host token across restarts so already-connected
 * makit-mirror extensions can re-authenticate on reconnect. Only mints a new
 * one if none is persisted.
 */
function loadOrCreateHostToken() {
    try {
        const p = resolvePath(homedir(), ".makit", "host.json");
        if (existsSync(p)) {
            const o = JSON.parse(readFileSync(p, "utf8"));
            if (typeof o.token === "string" && o.token)
                return o.token;
        }
    }
    catch {
        /* fall through to mint */
    }
    return randomBytes(32).toString("hex");
}
/**
 * Write ~/.makit/host.json (0600) so the `makit-mirror` pi extension — loaded
 * into an externally-launched pi — can discover the server and authenticate.
 */
function writeHostFile(port, fingerprint, token) {
    try {
        const dir = resolvePath(homedir(), ".makit");
        mkdirSync(dir, { recursive: true });
        writeFileSync(resolvePath(dir, "host.json"), JSON.stringify({ url: `wss://127.0.0.1:${port}`, port, fingerprint, token }, null, 2), { mode: 0o600 });
    }
    catch {
        // Non-fatal: the mirror extension just won't be able to auto-connect.
    }
}
/**
 * Print the transport posture at startup so the user knows whether makit is
 * private (Tailscale), exposed (LAN opt-in), or unreachable (loopback), and
 * how to reach the recommended state.
 */
function printTransport(mode, host) {
    switch (mode) {
        case "tailscale":
            console.log(`[makit] transport: Tailscale (${host}) — private ✓`);
            break;
        case "lan":
            console.log(`[makit] transport: LAN (${host}) — ⚠ exposed to this network.`);
            console.log(`[makit]   Only use --lan on trusted Wi-Fi. Prefer Tailscale on public networks.`);
            break;
        case "custom":
            console.log(`[makit] transport: custom host ${host} (--host override).`);
            break;
        case "loopback":
            console.log(`[makit] transport: loopback only — not reachable from other devices.`);
            console.log(`[makit]   Tailscale not detected. Install it for a private connection:`);
            console.log(`[makit]     https://tailscale.com/download  then run 'tailscale up' and restart makit.`);
            console.log(`[makit]   Or pass --lan to expose this (untrusted) local network.`);
            break;
    }
}
function printPairQr(registry, port, fingerprint, advertise, fallbackHost) {
    const host = advertise && advertise.length > 0 ? advertise : fallbackHost;
    const token = registry.mintPairToken();
    const url = buildPairUrl({ host, port, fingerprint, token });
    console.log("");
    qrcode.generate(url, { small: true });
    console.log(`[makit] ${url}`);
    console.log(`[makit] (expires in 5 minutes)`);
    console.log("");
}
main().catch((e) => {
    console.error(e);
    process.exit(1);
});
//# sourceMappingURL=index.js.map