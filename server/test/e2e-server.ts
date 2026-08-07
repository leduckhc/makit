#!/usr/bin/env tsx

import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager } from "../src/manager.js";
import { startWsServer } from "../src/server.js";
import { startBridge } from "../src/bridge.js";
import { loadOrCreateCert } from "../src/pairing/cert.js";
import { DeviceRegistry, type PairedDevice } from "../src/pairing/registry.js";
import { StubAdapter } from "../src/adapters/stub.js";
import { startFakeModelServer, type FakeModelHandle } from "./fake-model/server.js";
import type { UIResponse } from "../src/uicall.js";
import type { SessionConfigOption } from "../src/protocol.js";

/**
 * Real mode advertises that pi's LLM is swapped for the local fake-model server,
 * i.e. deterministic and keyless. That swap currently CANNOT take effect: pi runs
 * behind `pi-acp`, which spawns pi with a fixed argv and forwards no `-e`, so the
 * fake provider extension never loads and `makit-fake/fake-1` is never offered.
 * The old silent fallback was the operator's own configured model — real,
 * billable calls from a loop documented as keyless. Fail closed instead.
 */
function assertFakeModelInEffect(manager: SessionManager): void {
  const session = manager.allSessions()[0];
  const meta = [...(session?.events ?? [])].reverse().find((e) => e.kind === "session.meta");
  const options = (meta?.payload as { configOptions?: SessionConfigOption[] } | undefined)
    ?.configOptions;
  const current = options?.find((o) => o.id === "model")?.currentValue;
  if (current === FAKE_MODEL) return;
  const msg =
    `[makit] --mode real: the fake model is NOT in effect (model=${current ?? "unknown"}).\n` +
    `        pi-acp spawns pi with a fixed argv, so the fake provider extension never\n` +
    `        loads — turns will bill that provider for real.\n` +
    `        Re-run with MAKIT_E2E_ALLOW_REAL_MODEL=1 to accept that cost.`;
  if (process.env.MAKIT_E2E_ALLOW_REAL_MODEL === "1") {
    console.warn(msg);
    return;
  }
  console.error(msg);
  process.exit(1);
}

/** Absolute path to the fake-model provider extension pi loads via `-e`. */
const FAKE_PROVIDER_EXT = fileURLToPath(
  new URL("./fake-model/provider-extension.ts", import.meta.url),
);
/** Provider/model id registered by FAKE_PROVIDER_EXT. */
const FAKE_MODEL = "makit-fake/fake-1";

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

/**
 * A scripted `Exec` for the ports scanner: `lsof` (listeners), `ps` (process
 * table) and `lsof -d cwd` (the working dir), all fixed. The single listener
 * runs in `projectPath`, so attribution maps it to that project's primary
 * worktree and the app paints a glyph on the seeded row.
 */
function makeDeterministicPortsExec(projectPath: string) {
  const PID = 424242;
  return async (cmd: string, cmdArgs: string[]): Promise<{ code: number; stdout: string; stderr: string }> => {
    if (cmd === "lsof" && cmdArgs.includes("-iTCP")) {
      return { code: 0, stdout: [`p${PID}`, "u501", "f10", "PTCP", "n127.0.0.1:5173"].join("\n"), stderr: "" };
    }
    if (cmd === "ps") {
      return { code: 0, stdout: `  ${PID} 1 01:23:45 node vite --host 127.0.0.1 --port 5173`, stderr: "" };
    }
    if (cmd === "lsof") {
      return { code: 0, stdout: [`p${PID}`, "fcwd", `n${projectPath}`].join("\n"), stderr: "" };
    }
    return { code: 0, stdout: "", stderr: "" };
  };
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
  const makitHome = resolve(tmpdir(), `makit-e2e-${args.port}`);
  process.env.MAKIT_HOME = makitHome;
  seedDeviceRegistry(makitHome, args.bearer);

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

  // In real mode we run the genuine `pi` binary and ASK for the local
  // deterministic fake-model server. Whether pi actually honours that is
  // verified after the first session starts (see assertFakeModelInEffect) —
  // it cannot be assumed, and getting it wrong costs real money.
  let fakeModel: FakeModelHandle | undefined;
  if (args.mode === "real") {
    fakeModel = await startFakeModelServer();
    process.env.MAKIT_FAKE_MODEL_URL = fakeModel.url;
  }

  const manager = new SessionManager({
    projects: [args.project],
    adapterFactory: args.mode === "stub" ? () => new StubAdapter({ askUser }) : undefined,
    defaultModel: args.mode === "real" ? FAKE_MODEL : undefined,
  });

  wsHandle = startWsServer({
    host: "127.0.0.1",
    port: args.port,
    manager,
    cert,
    registry,
    // SPEC-41: a deterministic port scan so the e2e loop exercises the real
    // ports.snapshot frame path (attribute + broadcast) rather than an
    // indicator nothing feeds. One listener whose cwd IS the project, so it is
    // attributed to that project's primary worktree.
    ports: { exec: makeDeterministicPortsExec(args.project) },
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
    // Parity with serve.ts (SPEC-37): without this the harness would silently
    // bypass the makit-pi-usage route, so a real-mode run would "pass" while the
    // extension's reports went nowhere.
    onUsage: (sessionId, usage) => manager.getSession(sessionId)?.recordUsage(usage),
  });
  manager.setBridge({
    url: bridge.url,
    token: bridge.token,
    // Real mode loads the fake-model provider so pi's --model makit-fake/fake-1
    // resolves. Stub mode never spawns pi, so it needs no extensions.
    extensionPaths: args.mode === "real" ? [FAKE_PROVIDER_EXT] : [],
  });

  await manager.ensureDefaultSessions();
  if (args.mode === "real") assertFakeModelInEffect(manager);

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
    void fakeModel?.close();
    wsHandle.wss.close();
    wsHandle.https.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000).unref();
  });
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.stack ?? error.message : String(error));
  process.exit(1);
});
