/**
 * Agent catalog — the set of agents makit can spawn, surfaced to the app so the
 * user can pick one per session. Availability is probed from the environment
 * (binaries on PATH / bundled deps). Pure + dependency-light so it's unit
 * testable and cheap to call on demand.
 */

import { statSync, accessSync, constants } from "node:fs";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import type { SessionConfigOption } from "../protocol.js";

export type AgentTransport = "native" | "acp";

export interface AgentDescriptor {
  /** Stable id used on the wire + in spawn requests. */
  id: string;
  /** Human label for the picker. */
  label: string;
  transport: AgentTransport;
  /** Whether the backing binary/dep is present on this machine. */
  available: boolean;
  /**
   * Hash of the resolved binary identity (path + size + mtime) plus the
   * harness's catalog-affecting config inputs (pi: models.json + auth marker;
   * codex: config.toml + auth marker). A change here means the cached
   * {@link configOptions} may be stale and the harness must be re-probed
   * (SPEC-27). Cheap + deterministic — no `--version` subprocess.
   */
  fingerprint: string;
  /**
   * Cached configOptions snapshot from the throwaway probe (SPEC-27). Served
   * from the capability cache on {@link agents.list}; absent until the harness
   * has been probed (or when it advertises no options).
   */
  configOptions?: SessionConfigOption[];
}

/**
 * Resolve `cmd` to an absolute path: an explicit path is returned when it
 * exists; a bare name is searched on PATH (with Windows executable suffixes).
 * Returns `undefined` when nothing resolves.
 */
export function resolveBinPath(cmd: string): string | undefined {
  if (cmd.includes("/") || cmd.includes("\\")) return isRunnable(cmd) ? cmd : undefined;
  const dirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
  const exts = process.platform === "win32" ? ["", ".exe", ".cmd", ".bat"] : [""];
  for (const dir of dirs) {
    for (const ext of exts) {
      const candidate = join(dir, cmd + ext);
      if (isRunnable(candidate)) return candidate;
    }
  }
  return undefined;
}

/**
 * Whether [p] is a regular file that is executable (POSIX `X_OK`), so a
 * directory or a non-executable file named `pi`/`codex` on PATH does not mark
 * the harness available only to fail later at spawn time. Windows has no
 * executable bit, so a regular file suffices there.
 */
function isRunnable(p: string): boolean {
  try {
    if (!statSync(p).isFile()) return false;
    if (process.platform !== "win32") accessSync(p, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/** True if `cmd` is an absolute/relative existing file or resolves on PATH. */
export function onPath(cmd: string): boolean {
  return resolveBinPath(cmd) !== undefined;
}

// ---------- fingerprint (SPEC-27) ------------------------------------------

/**
 * Stat-based identity for a file (binary or config): `size:mtime`, or a stable
 * `absent` marker when the path is missing/unresolved. mtime is rounded to the
 * millisecond so a `touch` (which bumps mtime) reliably changes the digest
 * without depending on sub-ms precision. Deliberately avoids reading file
 * contents or shelling `--version` — the fingerprint must be cheap enough to
 * compute on every `agents.list`.
 */
function fileIdentity(path: string | undefined): string {
  if (!path) return "absent";
  try {
    const st = statSync(path);
    return `${st.size}:${Math.round(st.mtimeMs)}`;
  } catch {
    return "absent";
  }
}

/** pi's model catalog file — the primary catalog-affecting input for pi-acp. */
function piModelsFile(): string {
  return process.env.MAKIT_PI_MODELS_FILE || join(homedir(), ".pi", "agent", "models.json");
}

/** pi's provider-auth marker — logging in/out changes the available models. */
function piAuthFile(): string {
  return process.env.MAKIT_PI_AUTH_FILE || join(homedir(), ".pi", "agent", "auth.json");
}

/** codex's config file — model/reasoning defaults live here. */
function codexConfigFile(): string {
  return process.env.MAKIT_CODEX_CONFIG_FILE || join(homedir(), ".codex", "config.toml");
}

/** codex's auth marker — login state gates the model surface. */
function codexAuthFile(): string {
  return process.env.MAKIT_CODEX_AUTH_FILE || join(homedir(), ".codex", "auth.json");
}

/**
 * Per-agent fingerprint: a short hash of the resolved binary identity plus the
 * harness's catalog-affecting config inputs. Not a bare binary checksum —
 * editing `models.json` / `config.toml` or logging a provider in/out changes
 * the catalog without touching the binary (SPEC-27 decision 5).
 *
 * - pi (acp): the `pi-acp` + `pi` binaries, `~/.pi/agent/models.json`, and the
 *   `~/.pi/agent/auth.json` provider-auth marker.
 * - codex (native): the `codex` binary, `~/.codex/config.toml`, and the
 *   `~/.codex/auth.json` login marker.
 *
 * All config paths honour `MAKIT_*` env overrides (for tests / non-standard
 * installs), mirroring the binary overrides already used by {@link listAgents}.
 */
export function fingerprintAgent(agentId: string): string {
  const isCodex = agentId === "codex" || agentId === "codex-native";
  // Canonical id so the `codex-native` back-compat alias fingerprints exactly
  // like `codex` (same binary + config → same cached catalog).
  const canonical = isCodex ? "codex" : agentId;
  // Bump when the config-option PROJECTION logic changes (not just the binary):
  // the fingerprint tracks the harness's inputs, not the makit code, so an
  // adapter change (e.g. per-model reasoning efforts) must invalidate every
  // persisted `~/.makit/capability-cache.json` entry or stale options are
  // served to the new-session draft. Version 2: codex per-model efforts.
  const parts: string[] = [`catalog-schema:2`, `agent:${canonical}`];
  if (isCodex) {
    parts.push(`codex-bin:${fileIdentity(resolveBinPath(process.env.MAKIT_CODEX_BIN || "codex"))}`);
    parts.push(`codex-config:${fileIdentity(codexConfigFile())}`);
    parts.push(`codex-auth:${fileIdentity(codexAuthFile())}`);
  } else {
    // pi (and any other ACP agent) runs over `pi-acp`, which drives `pi`.
    parts.push(`pi-acp-bin:${fileIdentity(resolveBinPath(process.env.MAKIT_PI_ACP_BIN || "pi-acp"))}`);
    parts.push(`pi-bin:${fileIdentity(resolveBinPath(process.env.MAKIT_PI_BIN || "pi"))}`);
    parts.push(`pi-models:${fileIdentity(piModelsFile())}`);
    parts.push(`pi-auth:${fileIdentity(piAuthFile())}`);
  }
  return createHash("sha256").update(parts.join("|")).digest("hex").slice(0, 16);
}

/**
 * pi runs over ACP via the standalone `pi-acp` adapter (which spawns
 * `pi --mode rpc`). It is offered only when BOTH the `pi-acp` bridge binary and
 * the `pi` binary it drives resolve on PATH — no `npx` auto-install, so spawns
 * are deterministic and offline.
 */
function piAcpAvailable(): boolean {
  return (
    onPath(process.env.MAKIT_PI_ACP_BIN || "pi-acp") &&
    onPath(process.env.MAKIT_PI_BIN || "pi")
  );
}

/**
 * List the agents this makit host can offer. pi (ACP, via `pi-acp`) is listed
 * only when both `pi-acp` and `pi` resolve on PATH; codex (native, via
 * `codex app-server`) is listed when the `codex` binary resolves.
 */
export function listAgents(): AgentDescriptor[] {
  const agents: AgentDescriptor[] = [];
  if (piAcpAvailable()) {
    agents.push({
      id: "pi",
      label: "Pi (ACP)",
      transport: "acp",
      available: true,
      fingerprint: fingerprintAgent("pi"),
    });
  }
  // Native codex app-server path (first-party JSON-RPC), when codex is installed.
  if (onPath(process.env.MAKIT_CODEX_BIN || "codex")) {
    agents.push({
      id: "codex",
      label: "Codex (app-server)",
      transport: "native",
      available: true,
      fingerprint: fingerprintAgent("codex"),
    });
  }
  return agents;
}

/**
 * Transport for a given agent id: codex (and its legacy `codex-native` alias)
 * runs native via `codex app-server`; pi and every other ACP agent run over ACP.
 */
export function transportFor(agentId: string): AgentTransport {
  return agentId === "codex" || agentId === "codex-native" ? "native" : "acp";
}
