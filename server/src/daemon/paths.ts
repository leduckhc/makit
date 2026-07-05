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

export function pinoHome(): string {
  return process.env.PINO_HOME || join(homedir(), ".pino");
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
