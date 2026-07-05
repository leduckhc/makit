#!/usr/bin/env node
/**
 * pino — desktop server CLI.
 *
 * Usage:
 *   pino serve [--host 0.0.0.0] [--port 8787] [--project P]... [--no-auth]
 *   pino pair  [--host H] [--port P]                  # prints a QR + URL
 *
 * `pino serve` is the long-running server. `pino pair` is meant to be run
 * from a second terminal (or as a hotkey on an already-running server) to
 * mint a fresh pairing token. For M1 we co-locate both — `pino pair`
 * connects to the running server over a unix socket would be cleaner; for
 * now `pino serve` accepts a SIGUSR1 to print a new QR, and `pino pair`
 * works only if the user runs it as a one-shot _instead of_ `serve`.
 *
 * Simplest current UX: at startup, `pino serve` automatically prints one
 * QR with a fresh pair token. The user scans it; subsequent connects use
 * the persistent bearer.
 */

import { resolve } from "node:path";
import qrcode from "qrcode-terminal";
import { SessionManager } from "./manager.js";
import { projectsFile, loadProjectPaths, saveProjectPaths } from "./project-store.js";
import { buildFilteredAgentDir } from "./pi-agent-dir.js";
import { startWsServer } from "./server.js";
import { startBridge } from "./bridge.js";
import { fileURLToPath } from "node:url";
import { dirname, resolve as resolvePath } from "node:path";
import { loadOrCreateCert, localIPv4s } from "./pairing/cert.js";
import { DeviceRegistry } from "./pairing/registry.js";
import { buildPairUrl } from "./pairing/url.js";
import { MdnsAd } from "./pairing/mdns.js";
import { randomBytes } from "node:crypto";
import { writeFileSync, mkdirSync, symlinkSync, existsSync, rmSync, readFileSync, openSync } from "node:fs";
import { homedir } from "node:os";
import { spawn as childSpawn } from "node:child_process";
import { createServerBackend } from "./daemon/backend.js";
import { createControlServer, type ControlServerHandle } from "./daemon/control-server.js";
import { createDaemon, readPidFile } from "./daemon/service.js";
import { connectControlClient } from "./daemon/control-client.js";
import { controlSocketPath, pidFilePath, logFilePath, ensurePinoHome } from "./daemon/paths.js";
import { installService, uninstallService } from "./daemon/launchd.js";

/** pino version, read from package.json (best-effort). */
const PINO_VERSION: string = (() => {
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
      const child = childSpawn(cmd, args, { detached: true, stdio: ["ignore", logFd, logFd] });
      return { pid: child.pid, unref: () => child.unref() };
    },
    openLogFd: (p) => {
      ensurePinoHome();
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
    host: "0.0.0.0",
    port: 8787,
    projects: [] as string[],
    noAuth: false,
    printPair: true,
    advertise: process.env.PINO_ADVERTISE_HOST ?? "",
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--port") args.port = Number(argv[++i]);
    else if (a === "--host") args.host = String(argv[++i]);
    else if (a === "--project" || a === "-C") args.projects.push(resolve(String(argv[++i])));
    else if (a === "--no-auth") args.noAuth = true;
    else if (a === "--no-pair-qr") args.printPair = false;
    else if (a === "--advertise") args.advertise = String(argv[++i]);
  }
  if (args.projects.length === 0) args.projects.push(process.cwd());
  return args;
}
function bestLanHost(): string {
  const ips = localIPv4s();
  return ips[0] ?? "127.0.0.1";
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
  const KNOWN = new Set(["serve", "pair", "attach", "mirror", ...LIFECYCLE]);
  if (cmd && !KNOWN.has(cmd)) {
    console.error(
      `unknown command: ${cmd}\n` +
        `usage: pino serve|start|stop|restart|status|logs|service|pair|attach|mirror [...]`,
    );
    process.exit(2);
  }

  if (cmd === "mirror") {
    const { runMirror } = await import("./cli/mirror.js");
    await runMirror(process.argv.slice(3));
    return;
  }

  // `attach` is a client, not a server: connect to a running pino and drive
  // one session from the terminal. No cert/registry/manager needed here.
  if (cmd === "attach") {
    const argv = process.argv.slice(3);
    if (argv.includes("--pane")) {
      const { runPaneAttach } = await import("./cli/attach-pane.js");
      await runPaneAttach(argv);
    } else {
      const { runAttach } = await import("./cli/attach.js");
      await runAttach(argv);
    }
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
    const plistPath = resolvePath(homedir(), "Library", "LaunchAgents", "dev.pino.plist");
    if (sub === "install") {
      installService({
        label: "dev.pino",
        execPath: process.execPath,
        entry,
        logPath: logFilePath(),
        plistPath,
      });
      console.log(`[pino] launchd agent installed: ${plistPath}`);
      console.log(`[pino] it does NOT auto-start. Load it with: launchctl load ${plistPath}`);
    } else if (sub === "uninstall") {
      const removed = uninstallService({ plistPath });
      console.log(removed ? `[pino] launchd agent removed: ${plistPath}` : `[pino] no launchd agent installed`);
    } else {
      console.error("usage: pino service install|uninstall");
      process.exit(2);
    }
    return;
  }

  const opts = parseArgs(process.argv.slice(3));

  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();

  if (cmd === "pair") {
    // One-shot mint-and-print mode. Useful if the server is started elsewhere
    // and you just need a fresh QR. In M1 we share the same registry file so
    // tokens minted here are honoured by the running server.
    printPairQr(registry, opts.port, cert.fingerprint);
    process.exit(0);
  }
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

  // World D: a stable secret the pino-mirror pi extension uses to authenticate.
  // Written (0600) to ~/.pino/host.json so an externally-launched pi can find us.
  const hostToken = loadOrCreateHostToken();
  const ws = startWsServer({
    host: opts.host,
    port: opts.port,
    manager,
    cert,
    registry,
    trustLocalhost: opts.noAuth,
    hostToken,
  });
  writeHostFile(opts.port, cert.fingerprint, hostToken);
  ensureMirrorExtensionInstalled();

  // Loopback HTTP bridge so agent connectors (loaded inside each spawned
  // agent process) can talk back to pino.
  // The ws server's askDevice resolves with the srv.response envelope, which
  // is FLAT — the canonical UIResponse fields (kind, indices, answers, …) live
  // at the top level alongside v/t/id, not under a `.body`. Return it as-is.
  const bridge = await startBridge({
    askDevice: async (body) => {
      const { sessionId, ...rest } = body;
      const env = await ws.askDevice(rest as Record<string, unknown>, { sessionId });
      return env as unknown as import("./uicall.js").UIResponse;
    },
  });

  // Auto-discover every `.ts` connector in `server/connectors/`. Each one
  // gets loaded into the spawned `pi --mode rpc` process via `-e`. To add
  // a new agent, drop a file there — no code changes needed in pino.
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
    console.log("[pino] no agent connectors found in", connectorsDir);
  } else {
    console.log(
      `[pino] loading ${extensionPaths.length} connector(s):`,
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
      const env = await ws.askDevice(rest as Record<string, unknown>, { sessionId });
      return env as unknown as import("./uicall.js").UIResponse;
    },
    // Exclude TUI-only packages that can't run headless (see UI-TRANSPORT.md).
    agentDir: buildFilteredAgentDir(["@mammothb/pi-ask"]),
  });

  await manager.ensureDefaultSessions();

  const mdns = new MdnsAd();
  mdns.start({ port: opts.port, fingerprint: cert.fingerprint });

  // --- control plane (SPEC-01): let `pino status|stop|qr|devices|…` drive this
  // running server without a restart. Served by BOTH foreground `serve` and the
  // detached `pino start` process. ---
  ensurePinoHome(); // 0700 state dir before the control socket binds (perms race)
  const backend = createServerBackend({
    registry,
    manager,
    fingerprint: cert.fingerprint,
    host: opts.host,
    port: opts.port,
    advertiseHost: opts.advertise,
    version: PINO_VERSION,
    startedAt: Date.now(),
    now: () => Date.now(),
    connectedDeviceIds: ws.connectedDeviceIds,
    buildUrl: (token) =>
      buildPairUrl({
        host: opts.advertise && opts.advertise.length > 0 ? opts.advertise : bestLanHost(),
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
    console.log(`[pino] control socket: ${controlSocketPath()}`);
  } catch (e) {
    console.error(`[pino] control socket unavailable: ${(e as Error).message}`);
  }

  // Graceful shutdown: `pino stop` sends SIGTERM (as does the `server.stop`
  // control verb, via requestStop). Tear down the control socket, WS, and mDNS,
  // and remove our own PID file. Idempotent.
  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log("[pino] shutting down…");
    void control?.close().catch(() => {});
    try { mdns.stop(); } catch { /* best-effort */ }
    try { ws.wss.close(); } catch { /* best-effort */ }
    try { ws.https.close(); } catch { /* best-effort */ }
    // Only clear the PID file if it points at us (a detached `start` wrote it).
    if (readPidFile(pidFilePath()) === process.pid) rmSync(pidFilePath(), { force: true });
    setTimeout(() => process.exit(0), 100).unref();
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  console.log(`[pino] cert fingerprint: ${cert.fingerprint}`);
  console.log(`[pino] mDNS: advertising _pino._tcp on port ${opts.port}`);
  console.log(`[pino] projects:`);
  for (const p of manager.listProjects()) console.log(`  · ${p.name}  (${p.path})`);

  // Auto-rotate pair tokens while no devices are paired, so a QR is always
  // valid on screen. Stops once the first device pairs.
  let rotateTimer: NodeJS.Timeout | undefined;
  const maybeRotate = () => {
    if (registry.list().length === 0 && opts.printPair) {
      console.log("");
      console.log("[pino] no paired devices yet — scan this QR with the app:");
      printPairQr(registry, opts.port, cert.fingerprint, opts.advertise);
      // Re-mint just before the 5-minute TTL expires.
      rotateTimer = setTimeout(maybeRotate, 4 * 60 * 1000);
    } else {
      console.log(`[pino] ${registry.list().length} paired device(s). Send SIGUSR1 to mint a new pair token.`);
    }
  };
  maybeRotate();

  // SIGUSR1 → print a fresh pair QR on demand. Handy without restarting.
  process.on("SIGUSR1", () => {
    clearTimeout(rotateTimer);
    printPairQr(registry, opts.port, cert.fingerprint, opts.advertise);
    if (registry.list().length === 0) {
      rotateTimer = setTimeout(maybeRotate, 4 * 60 * 1000);
    }
  });

  if (opts.noAuth) {
    console.log("[pino] --no-auth: localhost connections bypass auth (dev only)");
    console.log(`[pino] dev: flutter run --dart-define=PINO_WS_URL=wss://127.0.0.1:${opts.port} --dart-define=PINO_FP=${cert.fingerprint}`);
  }
}

/**
 * Make `pino-mirror` auto-load into every `pi` by symlinking it (and its lone
 * runtime dep, `ws`) into pi's global extensions dir. Idempotent + best-effort,
 * so `pino serve` is all it takes for any `pi` to mirror while pino runs.
 */
function ensureMirrorExtensionInstalled(): void {
  try {
    const here = dirname(fileURLToPath(import.meta.url)); // server/src
    const extSrc = resolvePath(here, "../extensions/pino-mirror.ts");
    const wsPkg = resolvePath(here, "../node_modules/ws");
    if (!existsSync(extSrc) || !existsSync(wsPkg)) return;

    const extDir = resolvePath(homedir(), ".pi", "agent", "extensions");
    mkdirSync(resolvePath(extDir, "node_modules"), { recursive: true });
    const relink = (target: string, linkPath: string) => {
      try {
        rmSync(linkPath, { force: true });
        symlinkSync(target, linkPath);
      } catch {
        /* best-effort */
      }
    };
    relink(extSrc, resolvePath(extDir, "pino-mirror.ts"));
    relink(wsPkg, resolvePath(extDir, "node_modules", "ws"));
    disableConflictingAskExtension();
    console.log("[pino] mirror extension installed — any `pi` auto-mirrors while pino runs.");
  } catch {
    /* non-fatal */
  }

/**
 * Remove @mammothb/pi-ask from pi's settings if present. pino-mirror registers
 * the same `AskUserQuestion` tool (routed to the phone, with a TUI fallback),
 * and pi treats a duplicate tool name as a FATAL load error — so leaving pi-ask
 * enabled would stop pi from starting. Backed up once; re-enable any time with
 * `pi install npm:@mammothb/pi-ask`.
 */
function disableConflictingAskExtension(): void {
  try {
    const settings = resolvePath(homedir(), ".pi", "agent", "settings.json");
    if (!existsSync(settings)) return;
    const parsed = JSON.parse(readFileSync(settings, "utf8"));
    const pkgs: unknown = parsed.packages;
    if (!Array.isArray(pkgs)) return;
    const kept = pkgs.filter((p) => typeof p !== "string" || !p.includes("pi-ask"));
    if (kept.length === pkgs.length) return; // pi-ask not present
    const bak = settings + ".bak";
    if (!existsSync(bak)) writeFileSync(bak, JSON.stringify(parsed, null, 1));
    parsed.packages = kept;
    writeFileSync(settings, JSON.stringify(parsed, null, 1));
    console.log("[pino] disabled @mammothb/pi-ask (pino-mirror provides AskUserQuestion). Re-enable: pi install npm:@mammothb/pi-ask");
  } catch {
    /* non-fatal */
  }
}
}

/**
 * Reuse the existing host token across restarts so already-connected
 * pino-mirror extensions can re-authenticate on reconnect. Only mints a new
 * one if none is persisted.
 */
function loadOrCreateHostToken(): string {
  try {
    const p = resolvePath(homedir(), ".pino", "host.json");
    if (existsSync(p)) {
      const o = JSON.parse(readFileSync(p, "utf8"));
      if (typeof o.token === "string" && o.token) return o.token;
    }
  } catch {
    /* fall through to mint */
  }
  return randomBytes(32).toString("hex");
}

/**
 * Write ~/.pino/host.json (0600) so the `pino-mirror` pi extension — loaded
 * into an externally-launched pi — can discover the server and authenticate.
 */
function writeHostFile(port: number, fingerprint: string, token: string): void {
  try {
    const dir = resolvePath(homedir(), ".pino");
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      resolvePath(dir, "host.json"),
      JSON.stringify({ url: `wss://127.0.0.1:${port}`, port, fingerprint, token }, null, 2),
      { mode: 0o600 },
    );
  } catch {
    // Non-fatal: the mirror extension just won't be able to auto-connect.
  }
}

function printPairQr(registry: DeviceRegistry, port: number, fingerprint: string, advertise?: string) {
  const host = advertise && advertise.length > 0 ? advertise : bestLanHost();
  const token = registry.mintPairToken();
  const url = buildPairUrl({ host, port, fingerprint, token });
  console.log("");
  qrcode.generate(url, { small: true });
  console.log(`[pino] ${url}`);
  console.log(`[pino] (expires in 5 minutes)`);
  console.log("");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
