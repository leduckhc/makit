/**
 * Filesystem paths for the pino daemon (SPEC-01).
 *
 * Everything lives under `~/.pino` (overridable via `PINO_HOME`, matching
 * `pairing/cert.ts` and `pairing/registry.ts` so tests can redirect all state
 * to a temp dir). Centralized here so the service, control server, and control
 * client agree on the same locations.
 */

import { homedir } from "node:os";
import { join } from "node:path";
import { mkdirSync, chmodSync } from "node:fs";

export function pinoHome(): string {
  return process.env.PINO_HOME || join(homedir(), ".pino");
}

/** File mode for the private state dir: owner rwx only. */
export const PINO_HOME_MODE = 0o700;
/** File mode for secret-bearing files (pid, log, socket): owner rw only. */
export const PINO_FILE_MODE = 0o600;

/**
 * Ensure `~/.pino` exists and is private (mode 0700). This is the primary
 * mitigation for the socket/file permission race: even during the brief window
 * between binding the control socket and chmod-ing it to 0600, a 0700 parent
 * dir means no other user can traverse into it. `chmodSync` is best-effort so a
 * pre-existing loose dir gets tightened too.
 */
export function ensurePinoHome(): string {
  const home = pinoHome();
  mkdirSync(home, { recursive: true, mode: PINO_HOME_MODE });
  try {
    chmodSync(home, PINO_HOME_MODE);
  } catch {
    /* best-effort: perms may fail on exotic filesystems */
  }
  return home;
}

export function controlSocketPath(): string {
  return join(pinoHome(), "control.sock");
}

export function pidFilePath(): string {
  return join(pinoHome(), "pino.pid");
}

export function logFilePath(): string {
  return join(pinoHome(), "pino.log");
}
