#!/usr/bin/env tsx

import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { SessionManager } from "../src/manager.js";
import { startWsServer } from "../src/server.js";
import { startBridge } from "../src/bridge.js";
import { loadOrCreateCert } from "../src/pairing/cert.js";
import { DeviceRegistry, type PairedDevice } from "../src/pairing/registry.js";
import { StubAdapter } from "../src/adapters/stub.js";
import type { UIResponse } from "../src/uicall.js";

interface E2EArgs {
  port: number;
  bearer: string;
  mode: "stub" | "real";
  project: string;
}

function parseArgs(argv: string[]): E2EArgs {
  const args: E2EArgs = {
    port: 9787,
    bearer: "e2e-token",
    mode: "stub",
    project: process.cwd(),
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    switch (arg) {
      case "--port":
        args.port = Number(argv[++i]);
        break;
      case "--bearer":
        args.bearer = String(argv[++i]);
        break;
      case "--mode": {
        const mode = String(argv[++i]);
        if (mode !== "stub" && mode !== "real") throw new Error(`invalid --mode: ${mode}`);
        args.mode = mode;
        break;
      }
      case "--project":
        args.project = resolve(String(argv[++i]));
        break;
      default:
        throw new Error(`unknown arg: ${arg}`);
    }
  }

  if (!Number.isInteger(args.port) || args.port <= 0 || args.port > 65535) {
    throw new Error("--port must be a valid TCP port");
  }
  if (args.bearer.length === 0) throw new Error("--bearer must be non-empty");
  return args;
}

function seedDeviceRegistry(home: string, bearer: string): void {
  mkdirSync(home, { recursive: true });
  const device: PairedDevice = {
    id: "e2e-device",
    label: "e2e simulator",
    bearer,
    pairedAt: Date.now(),
    lastSeenAt: Date.now(),
  };
  writeFileSync(resolve(home, "devices.json"), JSON.stringify([device], null, 2), { mode: 0o600 });
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const pinoHome = resolve(tmpdir(), `pino-e2e-${args.port}`);
  process.env.PINO_HOME = pinoHome;
  seedDeviceRegistry(pinoHome, args.bearer);

  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();
  let wsHandle: ReturnType<typeof startWsServer>;

  const askUser = async (body: Record<string, unknown>): Promise<UIResponse> => {
    const { sessionId, ...requestBody } = body;
    const env = await wsHandle.askDevice(requestBody, {
      sessionId: typeof sessionId === "string" ? sessionId : undefined,
    });
    // Envelope is flat: response fields (kind, indices, answers, ...) live
    // at the top level, not under a `.body` property.
    return env as unknown as UIResponse;
  };

  const manager = new SessionManager({
    projects: [args.project],
    adapterFactory: args.mode === "stub" ? () => new StubAdapter({ askUser }) : undefined,
  });

  wsHandle = startWsServer({
    host: "127.0.0.1",
    port: args.port,
    manager,
    cert,
    registry,
  });

  // Wire the loopback bridge so agent connectors can do reverse-RPC
  // (e.g. StubAdapter askUserQuestion calls).
  const bridge = await startBridge({
    askDevice: async (body) => {
      const { sessionId, ...rest } = body;
      const env = await wsHandle.askDevice(rest as Record<string, unknown>, {
        sessionId,
      });
      return env as unknown as UIResponse;
    },
  });
  manager.setBridge({
    url: bridge.url,
    token: bridge.token,
    extensionPaths: [], // E2E tests don't load real extensions
  });

  await manager.ensureDefaultSessions();

  const printReady = () => {
    console.log(JSON.stringify({
      ready: true,
      host: "127.0.0.1",
      port: args.port,
      fp: cert.fingerprint,
      bearer: args.bearer,
    }));
  };
  if (wsHandle.https.listening) {
    printReady();
  } else {
    wsHandle.https.once("listening", printReady);
  }

  process.on("SIGTERM", () => {
    wsHandle.wss.close();
    wsHandle.https.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000).unref();
  });
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.stack ?? error.message : String(error));
  process.exit(1);
});
