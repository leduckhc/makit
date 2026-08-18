/**
 * Filesystem paths for the makit daemon (SPEC-daemon-control-plane).
 *
 * Everything lives under `~/.makit` (overridable via `MAKIT_HOME`, matching
 * `pairing/cert.ts` and `pairing/registry.ts` so tests can redirect all state
 * to a temp dir). Centralized here so the service, control server, and control
 * client agree on the same locations.
 */

import { homedir } from "node:os";
import { join } from "node:path";
import { mkdirSync, chmodSync } from "node:fs";

export function makitHome(): string {
  return process.env.MAKIT_HOME || join(homedir(), ".makit");
}

/** File mode for the private state dir: owner rwx only. */
export const MAKIT_HOME_MODE = 0o700;
/** File mode for secret-bearing files (pid, log, socket): owner rw only. */
export const MAKIT_FILE_MODE = 0o600;

/**
 * Ensure `~/.makit` exists and is private (mode 0700). This is the primary
 * mitigation for the socket/file permission race: even during the brief window
 * between binding the control socket and chmod-ing it to 0600, a 0700 parent
 * dir means no other user can traverse into it. `chmodSync` is best-effort so a
 * pre-existing loose dir gets tightened too.
 */
export function ensureMakitHome(): string {
  const home = makitHome();
  mkdirSync(home, { recursive: true, mode: MAKIT_HOME_MODE });
  try {
    chmodSync(home, MAKIT_HOME_MODE);
  } catch {
    /* best-effort: perms may fail on exotic filesystems */
  }
  return home;
}

export function controlSocketPath(): string {
  return join(makitHome(), "control.sock");
}

export function pidFilePath(): string {
  return join(makitHome(), "makit.pid");
}

export function logFilePath(): string {
  return join(makitHome(), "makit.log");
}
