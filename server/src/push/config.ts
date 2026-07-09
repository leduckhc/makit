/**
 * Push provider config loader (SPEC-07 W1).
 *
 * Reads `~/.pino/push.json`. When absent/invalid, `loadApnsConfig` returns
 * `null` and the caller falls back to {@link NoopPushSender} (graceful
 * degradation — Slice-1 behaviour, no wakes). This module does no network I/O.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { log } from "../log.js";
import { ApnsConfig, ApnsPushSender } from "./apns.js";
import { NoopPushSender, type PushSender } from "./sender.js";

function pinoHome(): string {
  return process.env.PINO_HOME || join(homedir(), ".pino");
}

function pushConfigPath(): string {
  return join(pinoHome(), "push.json");
}

/** Expand a leading `~/` to the user's home directory. */
function expandHome(p: string): string {
  return p.startsWith("~/") ? join(homedir(), p.slice(2)) : p;
}

/**
 * Load + validate the APNs config, or `null` if the file is missing, malformed,
 * or incomplete. Never throws — a bad config degrades to Noop, it does not
 * crash the server.
 */
export function loadApnsConfig(): ApnsConfig | null {
  const path = pushConfigPath();
  if (!existsSync(path)) return null;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { apns?: Record<string, unknown> };
    const a = parsed.apns;
    if (!a) return null;
    const keyPath = typeof a.keyPath === "string" ? expandHome(a.keyPath) : "";
    const keyId = typeof a.keyId === "string" ? a.keyId : "";
    const teamId = typeof a.teamId === "string" ? a.teamId : "";
    const bundleId = typeof a.bundleId === "string" ? a.bundleId : "";
    const env = a.env === "production" ? "production" : "sandbox";
    if (!keyPath || !keyId || !teamId || !bundleId) return null;
    if (!existsSync(keyPath)) return null;
    return { keyPath, keyId, teamId, bundleId, env };
  } catch {
    return null;
  }
}

/**
 * Build the wake sender from a (possibly-null) config, degrading to
 * {@link NoopPushSender} on ANY failure (SPEC-07 §5 graceful degradation).
 *
 * `ApnsPushSender`'s constructor parses the `.p8` via `createPrivateKey`, which
 * throws on a corrupt/non-EC key. Left unguarded that would crash server boot;
 * here it is caught and downgraded to a disabled sender so the server still
 * starts on the Slice-1 fallback. Never throws.
 */
export function createPushSender(config: ApnsConfig | null): PushSender {
  if (!config) return new NoopPushSender();
  try {
    const sender = new ApnsPushSender(config);
    log.info(`[pino] push: APNs sender active (${config.env}, ${config.bundleId})`);
    return sender;
  } catch (e) {
    log.warn(
      `[pino] push: APNs key invalid (${(e as Error).message}) — wakes disabled, Slice-1 fallback`,
    );
    return new NoopPushSender();
  }
}
