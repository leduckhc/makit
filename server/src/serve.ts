/**
 * makit — long-running server (`makit serve`) wiring.
 *
 * `runServe(opts)` owns the entire foreground server boot: cert/registry,
 * project persistence, the SQLite event store, the SessionManager, the WSS
 * server, the loopback bridge, connector discovery, mDNS, the control socket,
 * graceful shutdown, and the startup transport/QR output. `index.ts` parses
 * argv and dispatches subcommands; the serve path calls this.
 */

import { resolve } from "node:path";
import qrcode from "qrcode-terminal";
import { SessionManager } from "./manager.js";
import { SqliteEventStore } from "./storage/sqlite_event_store.js";
import { projectsFile, loadProjects, saveProjects, type PersistedProject } from "./project-store.js";
import { startWsServer } from "./server.js";
import { loadApnsConfig, createPushSender } from "./push/config.js";
import { type PushSender } from "./push/sender.js";
import { buildWakePayload } from "./push/payload.js";
import { startBridge } from "./bridge.js";
import { installProcessCrashHandlers } from "./crash_capture.js";
import { adoptLoginShellPathIfMinimal } from "./login_path.js";
import { fileURLToPath } from "node:url";
import { dirname, resolve as resolvePath } from "node:path";
import { loadOrCreateCert, chooseBindHost, type BindMode } from "./pairing/cert.js";
import { DeviceRegistry } from "./pairing/registry.js";
import { buildPairUrl } from "./pairing/url.js";
import { MdnsAd } from "./pairing/mdns.js";
import { mkdirSync, rmSync, readFileSync } from "node:fs";
import { createServerBackend } from "./daemon/backend.js";
import { createControlServer, type ControlServerHandle } from "./daemon/control-server.js";
import { readPidFile } from "./daemon/service.js";
import { controlSocketPath, pidFilePath, logFilePath, ensureMakitHome, makitHome } from "./daemon/paths.js";

/** makit version, read from package.json (best-effort). */
const MAKIT_VERSION: string = (() => {
  try {
    const pkg = resolvePath(dirname(fileURLToPath(import.meta.url)), "../package.json");
    return (JSON.parse(readFileSync(pkg, "utf8")).version as string) ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
})();

export function parseArgs(argv: string[]) {
  const args = {
    // "" means "auto": decide the bind host after parsing --host/--lan below,
    // secure-by-default (Tailscale > opt-in LAN > loopback).
    host: "",
    lan: false,
    port: 7777,
    projects: [] as string[],
    noAuth: false,
    persist: true,
    printPair: true,
    advertise: process.env.MAKIT_ADVERTISE_HOST ?? "",
    bindMode: "loopback" as BindMode | "custom",
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    // Reject a flag whose required value is missing (end of argv or another
    // flag) rather than persisting `undefined`/`NaN` into startup state.
    const requireValue = (): string => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`missing value for ${a}`);
      return v;
    };
    if (a === "--port") {
      const port = Number(requireValue());
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        throw new Error(`invalid --port (must be an integer in 1..65535): ${port}`);
      }
      args.port = port;
    } else if (a === "--host") args.host = requireValue();
    else if (a === "--lan") args.lan = true;
    else if (a === "--project" || a === "-C") args.projects.push(resolve(requireValue()));
    else if (a === "--no-auth") args.noAuth = true;
    else if (a === "--no-persist") args.persist = false;
    else if (a === "--no-pair-qr") args.printPair = false;
    else if (a === "--advertise") args.advertise = requireValue();
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
  // No project auto-default. The daemon just starts; projects come from the
  // persisted MAKIT_HOME/projects.json (loaded in runServe) and are added at
  // runtime by the app via the `project.add` API. `--project` remains an
  // optional convenience for terminal/dev/e2e use (the desktop app never
  // passes it).
  return args;
}

export type ServeArgs = ReturnType<typeof parseArgs>;

/**
 * Merge persisted `{ id, path }` projects with CLI `--project` roots, deduping
 * by resolved absolute path (first-seen wins, so a persisted id is preferred
 * over a duplicate CLI path). A persisted entry keeps its id; a CLI-only path
 * is passed as a bare string so the manager mints a fresh server id for it.
 */
function mergeProjects(
  persisted: PersistedProject[],
  cliPaths: string[],
): Array<PersistedProject | string> {
  const seen = new Set<string>();
  const out: Array<PersistedProject | string> = [];
  for (const p of persisted) {
    const key = resolve(p.path);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ id: p.id, path: key });
  }
  for (const raw of cliPaths) {
    const key = resolve(raw);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(key);
  }
  return out;
}

export async function runServe(opts: ServeArgs) {
  // In-app logging: capture uncaught errors / rejections into the server log
  // (~/.makit/makit.log) with a consistent, greppable tag before anything else.
  installProcessCrashHandlers();
  // A daemon spawned by the GUI app inherits launchd's PATH, where no agent
  // binary resolves. Repair it before anything can spawn one.
  adoptLoginShellPathIfMinimal();
  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();

  // Merge persisted projects with any CLI `--project` roots, deduping by
  // resolved path so a restart neither loses nor duplicates entries. The
  // manager mints server ids for CLI-only paths; persist the resulting
  // `{ id, path }` set once at startup so those ids (and migrated legacy
  // entries) are recorded and stay stable across restarts.
  const file = projectsFile();
  const persisted = loadProjects(file);
  const merged = mergeProjects(persisted, opts.projects);

  // Durable event log: persists sessions + their append-only event stream to a
  // single SQLite file (~/.makit/makit.db) so history survives a restart and
  // any client (mobile or desktop) can resume by `seq`. `--no-persist` opts out
  // (in-memory only, M0 behaviour).
  const store = opts.persist
    ? (() => {
        const dbPath = process.env.MAKIT_DB_FILE ?? resolvePath(makitHome(), "makit.db");
        mkdirSync(dirname(dbPath), { recursive: true });
        console.log(`[makit] event log: ${dbPath}`);
        return new SqliteEventStore(dbPath);
      })()
    : undefined;
  if (!store) console.log("[makit] --no-persist: sessions are in-memory only (lost on restart)");

  const manager = new SessionManager({
    projects: merged,
    onProjectsChanged: (projects) => saveProjects(file, projects),
    store,
  });
  // Record the manager's authoritative id↔path map now (CLI-only paths just got
  // fresh ids; legacy path-only entries got migrated ids).
  saveProjects(
    file,
    manager.listProjects().map((p) => ({ id: p.id, path: p.path })),
  );

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
    // SPEC-37: pi reports no usage over ACP, so the `makit-pi-usage` extension
    // posts it here. An unknown sessionId is dropped silently: the bridge is loopback
    // and a stale extension outliving its session is expected, not an error.
    onUsage: (sessionId, usage) => manager.getSession(sessionId)?.recordUsage(usage),
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
    // Same flat-envelope askDevice, reused by the pi ACP adapter interceptor.
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
