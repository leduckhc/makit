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
import { startWsServer } from "./server.js";
import { startBridge } from "./bridge.js";
import { fileURLToPath } from "node:url";
import { dirname, resolve as resolvePath } from "node:path";
import { loadOrCreateCert, localIPv4s } from "./pairing/cert.js";
import { DeviceRegistry } from "./pairing/registry.js";
import { buildPairUrl } from "./pairing/url.js";
import { MdnsAd } from "./pairing/mdns.js";

function parseArgs(argv: string[]) {
  const args = {
    host: "0.0.0.0",
    port: 8787,
    projects: [] as string[],
    noAuth: false,
    printPair: true,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--port") args.port = Number(argv[++i]);
    else if (a === "--host") args.host = String(argv[++i]);
    else if (a === "--project" || a === "-C") args.projects.push(resolve(String(argv[++i])));
    else if (a === "--no-auth") args.noAuth = true;
    else if (a === "--no-pair-qr") args.printPair = false;
  }
  if (args.projects.length === 0) args.projects.push(process.cwd());
  return args;
}

function bestLanHost(): string {
  const ips = localIPv4s();
  return ips[0] ?? "127.0.0.1";
}

async function main() {
  const cmd = process.argv[2];
  if (cmd && cmd !== "serve" && cmd !== "pair") {
    console.error(`unknown command: ${cmd}\nusage: pino serve|pair [...]`);
    process.exit(2);
  }
  const opts = parseArgs(process.argv.slice(3));

  const cert = loadOrCreateCert();
  const registry = new DeviceRegistry();

  if (cmd === "pair") {
    // One-shot mint-and-print mode. Useful if the server is started elsewhere
    // and you just need a fresh QR. In M1 we share the same registry file so
    // tokens minted here are honoured by the running server.
    printPairQr(registry, opts.port);
    process.exit(0);
  }

  const manager = new SessionManager({ projects: opts.projects });

  const ws = startWsServer({
    host: opts.host,
    port: opts.port,
    manager,
    cert,
    registry,
    trustLocalhost: opts.noAuth,
  });

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
  });

  await manager.ensureDefaultSessions();

  const mdns = new MdnsAd();
  mdns.start({ port: opts.port, fingerprint: cert.fingerprint });

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
      printPairQr(registry, opts.port);
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
    printPairQr(registry, opts.port);
    if (registry.list().length === 0) {
      rotateTimer = setTimeout(maybeRotate, 4 * 60 * 1000);
    }
  });

  if (opts.noAuth) {
    console.log("[pino] --no-auth: localhost connections bypass auth (dev only)");
    console.log(`[pino] dev: flutter run --dart-define=PINO_WS_URL=wss://127.0.0.1:${opts.port} --dart-define=PINO_FP=${cert.fingerprint}`);
  }
}

function printPairQr(registry: DeviceRegistry, port: number) {
  const host = bestLanHost();
  const cert = loadOrCreateCert();
  const token = registry.mintPairToken();
  const url = buildPairUrl({ host, port, fingerprint: cert.fingerprint, token });
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
