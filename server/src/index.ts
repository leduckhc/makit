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
 * so the loopback HTTP bridge and the flutter dev loop keep working.
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
import { SqliteEventStore } from "./storage/sqlite_event_store.js";
import { projectsFile, loadProjectPaths, saveProjectPaths } from "./project-store.js";
import { startWsServer } from "./server.js";
import { loadApnsConfig, createPushSender } from "./push/config.js";
import { type PushSender } from "./push/sender.js";
import { buildWakePayload } from "./push/payload.js";
import { startBridge } from "./bridge.js";
import { fileURLToPath } from "node:url";
import { dirname, resolve as resolvePath } from "node:path";
import { loadOrCreateCert, chooseBindHost, type BindMode } from "./pairing/cert.js";
import { DeviceRegistry } from "./pairing/registry.js";
import { buildPairUrl } from "./pairing/url.js";
import { MdnsAd } from "./pairing/mdns.js";
import { mkdirSync, rmSync, readFileSync, openSync } from "node:fs";
import { homedir } from "node:os";
import { spawn as childSpawn } from "node:child_process";
import { createServerBackend } from "./daemon/backend.js";
import { createControlServer, type ControlServerHandle } from "./daemon/control-server.js";
import { createDaemon, readPidFile } from "./daemon/service.js";
import { connectControlClient } from "./daemon/control-client.js";
import { controlSocketPath, pidFilePath, logFilePath, ensureMakitHome } from "./daemon/paths.js";
import { installService, uninstallService } from "./daemon/launchd.js";

/** makit version, read from package.json (best-effort). */
const MAKIT_VERSION: string = (() => {
  try {
    const pkg = resolvePath(dirname(fileURLToPath(import.meta.url)), "../package.json");
    return (JSON.parse(readFileSync(pkg, "utf8")).version as string) ?? "0.0.0";
  } catch {
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
      } catch {
        return false;
      }
    },
    connect: (sp) => connectControlClient(sp),
  });
}

function parseArgs(argv: string[]) {
  const args = {
    // "" means "auto": decide the bind host after parsing --host/--lan below,
    // secure-by-default (Tailscale > opt-in LAN > loopback).
    host: "",
    lan: false,
    port: 8787,
    projects: [] as string[],
    noAuth: false,
    persist: true,
    printPair: true,
    advertise: process.env.MAKIT_ADVERTISE_HOST ?? "",
    bindMode: "loopback" as BindMode | "custom",
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--port") args.port = Number(argv[++i]);
    else if (a === "--host") args.host = String(argv[++i]);
    else if (a === "--lan") args.lan = true;
    else if (a === "--project" || a === "-C") args.projects.push(resolve(String(argv[++i])));
    else if (a === "--no-auth") args.noAuth = true;
    else if (a === "--no-persist") args.persist = false;
    else if (a === "--no-pair-qr") args.printPair = false;
    else if (a === "--advertise") args.advertise = String(argv[++i]);
  }
  if (args.host) {
    // Explicit --host overrides the secure-by-default decision (escape hatch,
    // e.g. --host 0.0.0.0 for all interfaces).
    args.bindMode = "custom";
  } else {
    const decision = chooseBindHost({ allowLan: args.lan });
    args.host = decision.host;
    args.bindMode = decision.mode;
  }
  if (args.projects.length === 0) args.projects.push(process.cwd());
  return args;
}

/** Dedupe paths by their resolved absolute form, preserving first-seen order. */
function dedupeResolved(paths: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const p of paths) {
    const key = resolve(p);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(key);
  }
  return out;
}

async function main() {
  const cmd = process.argv[2];
  const LIFECYCLE = new Set(["start", "stop", "restart", "status", "logs", "service"]);
  const KNOWN = new Set(["serve", "pair", "qr", "devices", "sessions", "attach", ...LIFECYCLE]);
  if (cmd && !KNOWN.has(cmd)) {
    console.error(
      `unknown command: ${cmd}\n` +
        `usage: makit serve|start|stop|restart|status|logs|service|pair|qr|devices|sessions|attach [...]`,
    );
    process.exit(2);
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
    const { runAttach } = await import("./cli/attach.js");
    await runAttach(process.argv.slice(3));
    return;
  }

  // --- background service lifecycle (SPEC-01) — thin clients of the control
  // socket / process management. These do not need cert/manager. ---
  if (LIFECYCLE.has(cmd!) && cmd !== "service") {
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
    if (cmd === "start") code = await daemon.start(serveOpts);
    else if (cmd === "stop") code = await daemon.stop();
    else if (cmd === "restart") code = await daemon.restart(serveOpts);
    else if (cmd === "status") code = await daemon.status();
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
    } else if (sub === "uninstall") {
      const removed = uninstallService({ plistPath });
      console.log(removed ? `[makit] launchd agent removed: ${plistPath}` : `[makit] no launchd agent installed`);
    } else {
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

  // Durable event log: persists sessions + their append-only event stream to a
  // single SQLite file (~/.makit/makit.db) so history survives a restart and
  // any client (mobile or desktop) can resume by `seq`. `--no-persist` opts out
  // (in-memory only, M0 behaviour).
  const store = opts.persist
    ? (() => {
        const dbPath = process.env.MAKIT_DB_FILE ?? resolvePath(homedir(), ".makit", "makit.db");
        mkdirSync(dirname(dbPath), { recursive: true });
        console.log(`[makit] event log: ${dbPath}`);
        return new SqliteEventStore(dbPath);
      })()
    : undefined;
  if (!store) console.log("[makit] --no-persist: sessions are in-memory only (lost on restart)");

  const manager = new SessionManager({
    projects: merged,
    onProjectsChanged: (paths) => saveProjectPaths(file, paths),
    store,
  });

  // SPEC-07: choose the content-free wake sender. Absent/invalid push.json →
  // NoopPushSender (graceful degradation: wakes are no-ops, Slice-1 fallback).
  // The WakeCoordinator + onUndeliverable wiring lives inside server.ts, which
  // owns `connectedDeviceIds`; index.ts only picks the sender and forwards it.
  const apnsConfig = loadApnsConfig();
  const sender: PushSender = createPushSender(apnsConfig);
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
    sender,
    buildWakePayload,
  });

  // Loopback HTTP bridge so agent connectors (loaded inside each spawned
  // agent process) can talk back to makit.
  // The ws server's askDevice resolves with the srv.response envelope, which
  // is FLAT — the canonical UIResponse fields (kind, indices, answers, …) live
  // at the top level alongside v/t/id, not under a `.body`. We validate it at
  // this trust boundary (decodeUIResponse) and reject a malformed/hostile
  // reply rather than blindly cast it into an agent reply.
  const { decodeUIResponse } = await import("./protocol/codec.js");
  const askDeviceValidated = async (
    body: Record<string, unknown>,
    sessionId: string | undefined,
  ): Promise<import("./uicall.js").UIResponse> => {
    const env = await ws.askDevice(body, { sessionId });
    const resp = decodeUIResponse(env);
    if (!resp) throw new Error("srv.response failed validation (malformed device reply)");
    return resp;
  };
  const bridge = await startBridge({
    askDevice: async (body) => {
      const { sessionId, ...rest } = body;
      return askDeviceValidated(rest as Record<string, unknown>, sessionId);
    },
  });

  // Auto-discover every `.ts` connector in `server/connectors/`. Each one
  // gets loaded into the spawned `pi --mode rpc` process via `-e`. To add
  // a new agent, drop a file there — no code changes needed in makit.
  const connectorsDir = resolvePath(
    dirname(fileURLToPath(import.meta.url)),
    "../connectors",
  );
  const { readdirSync, existsSync } = await import("node:fs");
  const extensionPaths = existsSync(connectorsDir)
    ? readdirSync(connectorsDir)
        .filter((f) => f.endsWith(".ts"))
        .map((f) => resolvePath(connectorsDir, f))
    : [];
  if (extensionPaths.length === 0) {
    console.log("[makit] no agent connectors found in", connectorsDir);
  } else {
    console.log(
      `[makit] loading ${extensionPaths.length} connector(s):`,
      extensionPaths.map((p) => p.split("/").pop()).join(", "),
    );
  }
  manager.setBridge({
    url: bridge.url,
    token: bridge.token,
    extensionPaths,
    // Same flat-envelope askDevice, reused by the PiAdapter UI interceptor.
    askUser: async (call) => {
      const { sessionId, ...rest } = call;
      return askDeviceValidated(rest as Record<string, unknown>, sessionId);
    },
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
    buildUrl: (token) =>
      buildPairUrl({
        host: opts.advertise && opts.advertise.length > 0 ? opts.advertise : opts.host,
        port: opts.port,
        fingerprint: cert.fingerprint,
        token,
      }),
    requestStop: () => process.kill(process.pid, "SIGTERM"),
    logPath: logFilePath(),
  });
  let control: ControlServerHandle | undefined;
  try {
    control = await createControlServer({ socketPath: controlSocketPath(), backend });
    console.log(`[makit] control socket: ${controlSocketPath()}`);
  } catch (e) {
    console.error(`[makit] control socket unavailable: ${(e as Error).message}`);
  }

  // Graceful shutdown: `makit stop` sends SIGTERM (as does the `server.stop`
  // control verb, via requestStop). Tear down the control socket, WS, and mDNS,
  // and remove our own PID file. Idempotent.
  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log("[makit] shutting down…");
    void control?.close().catch(() => {});
    try { mdns.stop(); } catch { /* best-effort */ }
    try { ws.wss.close(); } catch { /* best-effort */ }
    try { ws.https.close(); } catch { /* best-effort */ }
    try { ws.localHttps?.close(); } catch { /* best-effort */ }
    // Only clear the PID file if it points at us (a detached `start` wrote it).
    if (readPidFile(pidFilePath()) === process.pid) rmSync(pidFilePath(), { force: true });
    setTimeout(() => process.exit(0), 100).unref();
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  console.log(`[makit] cert fingerprint: ${cert.fingerprint}`);
  console.log(`[makit] mDNS: advertising _makit._tcp on port ${opts.port}`);
  console.log(`[makit] projects:`);
  for (const p of manager.listProjects()) console.log(`  · ${p.name}  (${p.path})`);

  printTransport(opts.bindMode, opts.host);

  // Auto-rotate pair tokens while no devices are paired, so a QR is always
  // valid on screen. Stops once the first device pairs.
  let rotateTimer: NodeJS.Timeout | undefined;
  const maybeRotate = () => {
    if (registry.list().length === 0 && opts.printPair) {
      console.log("");
      console.log("[makit] no paired devices yet — scan this QR with the app:");
      printPairQr(registry, opts.port, cert.fingerprint, opts.advertise, opts.host);
      // Re-mint just before the 5-minute TTL expires.
      rotateTimer = setTimeout(maybeRotate, 4 * 60 * 1000);
    } else {
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
 * Print the transport posture at startup so the user knows whether makit is
 * private (Tailscale), exposed (LAN opt-in), or unreachable (loopback), and
 * how to reach the recommended state.
 */
function printTransport(mode: BindMode | "custom", host: string): void {
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

function printPairQr(
  registry: DeviceRegistry,
  port: number,
  fingerprint: string,
  advertise: string | undefined,
  fallbackHost: string,
) {
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
