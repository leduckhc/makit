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
import { guardAgainstRealBilling, currentModelFromEvents, FAKE_MODEL } from "./fake-model/billing-guard.js";

/** Absolute path to the fake-model provider extension pi loads via `-e`. */
const FAKE_PROVIDER_EXT = fileURLToPath(
  new URL("./fake-model/provider-extension.ts", import.meta.url),
);

function assertFakeModelInEffect(manager: SessionManager): void {
  guardAgainstRealBilling(
    "--mode real",
    currentModelFromEvents(manager.allSessions()[0]?.events ?? []),
  );
}

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
 * table), `lsof -d cwd` (the working dir) and `docker ps`, all fixed.
 *
 * It stages one of every state the ports UI can render, so the running app can be
 * driven and screenshotted without waiting for a machine to happen to be in each
 * of them:
 *
 *  - `:5173 vite`      — owned by the project, healthy → killable, watchable, and
 *                        the one eligible for a browser forward (SPEC-44).
 *  - `:5175 vite`      — owned but **refused** (a wedged zombie): the case SPEC-43
 *                        exists for, and NOT forwardable (it never spoke HTTP).
 *  - `:5432 postgres`  — published by a docker container, bound `0.0.0.0`
 *                        (SPEC-42 D13: docker is ownership, reach stays exposed).
 *  - `:5180`, `:5181`  — orphans, running from a worktree that is gone, so the
 *                        orphans section and `Kill all orphans (2)` appear.
 *  - `:22 sshd`        — an unowned system listener, which must be refused.
 *
 * PIDs are fictional, so `signal` is injected by the caller and NOTHING is ever
 * signalled for real — a `process.kill(424242)` could land on an unrelated
 * process. A "killed" pid simply stops appearing in the scan, which is what makes
 * the kill visibly work in the UI.
 */
const E2E_PIDS = {
  vite: 424242,
  zombie: 424244,
  docker: 424243,
  orphanA: 424245,
  orphanB: 424246,
  sshd: 424247,
} as const;

/** Where the orphans are running from — a worktree the user has removed. */
const E2E_GONE_WORKTREE = "/tmp/makit-e2e-removed-wt";

function makeDeterministicPortsExec(projectPath: string, killed: Set<number>) {
  const alive = (pid: number): boolean => !killed.has(pid);
  return async (cmd: string, cmdArgs: string[]): Promise<{ code: number; stdout: string; stderr: string }> => {
    if (cmd === "lsof" && cmdArgs.includes("-iTCP")) {
      const rows: string[] = [];
      const push = (pid: number, addr: string, uid = "501"): void => {
        if (!alive(pid)) return;
        rows.push(`p${pid}`, `u${uid}`, "PTCP", `n${addr}`);
      };
      push(E2E_PIDS.vite, "127.0.0.1:5173");
      push(E2E_PIDS.zombie, "127.0.0.1:5175");
      push(E2E_PIDS.docker, "0.0.0.0:5432");
      push(E2E_PIDS.orphanA, "127.0.0.1:5180");
      push(E2E_PIDS.orphanB, "127.0.0.1:5181");
      push(E2E_PIDS.sshd, "0.0.0.0:22", "0");
      return { code: 0, stdout: rows.join("\n"), stderr: "" };
    }
    if (cmd === "ps") {
      // `etime` drives `startedAt`, which is the identity field a kill verifies.
      return {
        code: 0,
        stdout: [
          `  ${E2E_PIDS.vite} 1 01:23:45 node vite --host 127.0.0.1 --port 5173`,
          `  ${E2E_PIDS.zombie} 1 06:12:00 node vite --host 127.0.0.1 --port 5175`,
          `  ${E2E_PIDS.docker} 1 02:00:00 com.docker.backend`,
          `  ${E2E_PIDS.orphanA} 1 48:00:00 node vite --port 5180`,
          `  ${E2E_PIDS.orphanB} 1 48:00:00 node storybook dev -p 5181`,
          `  ${E2E_PIDS.sshd} 1 240:00:00 /usr/sbin/sshd`,
        ].join("\n"),
        stderr: "",
      };
    }
    if (cmd === "docker") {
      return {
        code: 0,
        stdout: `e2e-db-1\t0.0.0.0:5432->5432/tcp\t${projectPath}/compose.yml`,
        stderr: "",
      };
    }
    if (cmd === "lsof") {
      return {
        code: 0,
        stdout: [
          `p${E2E_PIDS.vite}`, "fcwd", `n${projectPath}`,
          `p${E2E_PIDS.zombie}`, "fcwd", `n${projectPath}`,
          // The orphans' cwd is the REMOVED worktree: that plus the port history
          // below is what makes them classify as orphans (SPEC-42 D10).
          `p${E2E_PIDS.orphanA}`, "fcwd", `n${E2E_GONE_WORKTREE}`,
          `p${E2E_PIDS.orphanB}`, "fcwd", `n${E2E_GONE_WORKTREE}`,
          `p${E2E_PIDS.sshd}`, "fcwd", "n/",
        ].join("\n"),
        stderr: "",
      };
    }
    return { code: 0, stdout: "", stderr: "" };
  };
}

/**
 * Pre-seed the two on-disk stores the ports feature reads, so the app opens with
 * a populated screen instead of needing several minutes of history to accrue:
 *  - `port-history.json` remembers a worktree that is GONE (its two ports then
 *    classify as orphans),
 *  - `watched-ports.json` marks `:5173` as watched, so the detail sheet's toggle
 *    renders in its on state.
 */
function seedPortStores(home: string, projectPath: string): void {
  mkdirSync(home, { recursive: true });
  const now = Date.now();
  writeFileSync(
    resolve(home, "port-history.json"),
    JSON.stringify({
      entries: [
        {
          worktreePath: E2E_GONE_WORKTREE,
          branch: "feat/desktop-tabs",
          ports: [5180, 5181],
          firstSeen: now - 7 * 24 * 60 * 60 * 1000,
          lastSeen: now - 2 * 24 * 60 * 60 * 1000,
        },
      ],
    }, null, 2),
  );
  writeFileSync(
    resolve(home, "watched-ports.json"),
    JSON.stringify([{ worktreePath: projectPath, port: 5173 }], null, 2),
  );
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
  seedPortStores(makitHome, args.project);

  /** Pids a kill has "terminated" — they stop appearing in the scripted scan. */
  const killedPids = new Set<number>();

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
    ports: {
      exec: makeDeterministicPortsExec(args.project, killedPids),
      // Fictional pids: never signal for real (see makeDeterministicPortsExec).
      // A SIGTERM just removes the listener from the next scan, so the kill is
      // visibly effective in the UI.
      signal: (pid) => {
        killedPids.add(pid);
      },
      sleep: async () => {},
    },
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
