#!/usr/bin/env tsx

/**
 * Full-stack control-plane e2e harness for the macOS desktop control app
 * (SPEC-03). The counterpart of `e2e-server.ts` (which serves the mobile client
 * over WS): this one exposes the daemon's **control socket** so the real
 * desktop screens (`app/integration_test/desktop/`) can drive the genuine
 * NDJSON control protocol against a real {@link createServerBackend}.
 *
 * Like the mobile harness it uses the in-process {@link StubAdapter} instead of
 * spawning the real `pi` binary — the control plane (status/devices/sessions/
 * pair/logs) is what we're proving, not agent execution. No WS, TLS, or mDNS is
 * started: the control socket is the whole surface under test.
 *
 * It seeds one paired device and one default session so `devices.list` and
 * `sessions.list` return real rows, writes a couple of log lines so `logs.tail`
 * has content, then prints a single `{"ready":true,...}` line carrying the
 * socket path the orchestration script forwards to Flutter as
 * `--dart-define=MAKIT_CONTROL_SOCK`.
 */

import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { SessionManager } from "../src/manager.js";
import { StubAdapter } from "../src/adapters/stub.js";
import { loadOrCreateCert } from "../src/pairing/cert.js";
import { DeviceRegistry, type PairedDevice } from "../src/pairing/registry.js";
import { buildPairUrl } from "../src/pairing/url.js";
import { createControlServer } from "../src/daemon/control-server.js";
import { createServerBackend } from "../src/daemon/backend.js";
import {
  controlSocketPath,
  logFilePath,
  ensureMakitHome,
  makitHome,
} from "../src/daemon/paths.js";

const HOST = "127.0.0.1";
const PORT = 7788;
const DEVICE_LABEL = "e2e phone";

function seedDeviceRegistry(home: string): void {
  const device: PairedDevice = {
    id: "e2e-device",
    label: DEVICE_LABEL,
    bearer: "e2e-token",
    pairedAt: Date.now() - 3 * 24 * 60 * 60 * 1000,
    lastSeenAt: Date.now() - 5 * 60 * 1000,
  };
  writeFileSync(resolve(home, "devices.json"), JSON.stringify([device], null, 2), {
    mode: 0o600,
  });
}

async function main(): Promise<void> {
  // Redirect all daemon state to a per-run temp dir so the harness never
  // touches the developer's real `~/.makit`. The orchestration script may also
  // set MAKIT_HOME; honour it if present.
  if (!process.env.MAKIT_HOME) {
    process.env.MAKIT_HOME = resolve(tmpdir(), `makit-control-e2e-${process.pid}`);
  }
  const home = ensureMakitHome();

  seedDeviceRegistry(home);
  // Seed a log so `logs.tail` returns deterministic content.
  writeFileSync(logFilePath(), "[makit] control-plane e2e harness\n[makit] ready\n", {
    mode: 0o600,
  });

  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();

  // Stub adapter: a default session is created without spawning `pi`.
  const manager = new SessionManager({
    projects: [home],
    adapterFactory: () => new StubAdapter(),
  });
  await manager.ensureDefaultSessions();
  // The desktop "Running sessions" surface intentionally hides idle/exited
  // sessions (SessionsScreen._isActive). A freshly-spawned StubAdapter session
  // is `idle`, so drive the seeded default session to `running` — otherwise the
  // control-plane e2e would only ever see the empty state and never exercise
  // the real session-row render path.
  for (const session of manager.allSessions()) {
    session.backfill([
      { ts: Date.now(), kind: "session.status", payload: { status: "running" } },
    ]);
  }

  const startedAt = Date.now();
  const backend = createServerBackend({
    registry,
    manager,
    fingerprint: cert.fingerprint,
    host: HOST,
    port: PORT,
    advertiseHost: HOST,
    version: "e2e",
    startedAt,
    now: () => Date.now(),
    // No live WS in the control-plane harness, so no device is "connected".
    connectedDeviceIds: () => new Set<string>(),
    buildUrl: (token) =>
      buildPairUrl({ host: HOST, port: PORT, fingerprint: cert.fingerprint, token }),
    requestStop: () => process.kill(process.pid, "SIGTERM"),
    logPath: logFilePath(),
  });

  const control = await createControlServer({ socketPath: controlSocketPath(), backend });

  console.log(
    JSON.stringify({
      ready: true,
      socket: controlSocketPath(),
      home: makitHome(),
      fp: cert.fingerprint,
    }),
  );

  const shutdown = () => {
    void control.close().finally(() => process.exit(0));
    setTimeout(() => process.exit(0), 1000).unref();
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? (error.stack ?? error.message) : String(error));
  process.exit(1);
});
