/**
 * Computer use — registering the external `cua-driver` binary as a stdio MCP
 * server for makit's codex sessions, so the agent can drive the host desktop
 * (click / type / scroll / capture) while the phone watches and approves.
 *
 * makit does not implement desktop driving itself, and deliberately does not
 * proxy it: `cua-driver` is spawned by the *agent*, so makit never sees the
 * MCP traffic. That has two consequences worth stating plainly:
 *
 * - makit cannot add tool-level guardrails (blocked key combos, blocked `type`
 *   payloads) the way an in-process harness can. Safety rests on the agent's
 *   own approval flow plus cua-driver's `standard` permission mode, which stops
 *   at its protected boundary.
 * - Screenshots come back as image blocks inside MCP tool results; those are
 *   ingested by {@link CodexEventMapper} into the media store so the app can
 *   render them (SPEC-22).
 *
 * Off by default. Registering a desktop-driving MCP server into every codex
 * session is not a safe default, so it takes an explicit opt-in.
 *
 * - `MAKIT_COMPUTER_USE=1` — enable.
 * - `MAKIT_CUA_DRIVER_CMD=/path/to/cua-driver` — override binary resolution
 *   (local builds / CI), mirroring Hermes' `HERMES_CUA_DRIVER_CMD`.
 *
 * Only the codex adapter is wired: `codex app-server` accepts `-c` config
 * overrides, so the server is declared per-spawn without touching the user's
 * `~/.codex/config.toml`. The pi path has no route — `pi-acp` accepts ACP
 * `mcpServers` and silently ignores it (verified against pi-acp 0.0.32:
 * `mcpCapabilities: {http:false, sse:false}`), because pi has no MCP client.
 * For pi, cua's documented fallback is one-shot `cua-driver call …` from pi's
 * own shell tool, which needs nothing from makit.
 */

import { resolveBinPath } from "./catalog.js";

/** The MCP server name codex registers the driver under. */
export const CUA_SERVER_NAME = "cua_driver";

export type ComputerUse =
  | { enabled: true; driverPath: string }
  /** `not-enabled`: no opt-in. `driver-missing`: opted in, no binary found. */
  | { enabled: false; reason: "not-enabled" | "driver-missing" };

/**
 * Whether computer use is on for this process, and which binary would back it.
 * `resolve` is injected so this stays a pure unit (defaults to a PATH lookup).
 */
export function resolveComputerUse(
  env: Record<string, string | undefined>,
  resolve: (cmd: string) => string | undefined = resolveBinPath,
): ComputerUse {
  if (env.MAKIT_COMPUTER_USE !== "1") return { enabled: false, reason: "not-enabled" };
  const driverPath = env.MAKIT_CUA_DRIVER_CMD || resolve("cua-driver");
  if (!driverPath) return { enabled: false, reason: "driver-missing" };
  return { enabled: true, driverPath };
}

/**
 * `codex app-server` CLI overrides that declare the driver as a stdio MCP
 * server for this spawn only. Telemetry is forced off (cua-driver ships with
 * PostHog usage telemetry enabled upstream; a remote-controlled desktop session
 * is not something makit reports on the user's behalf).
 */
export function codexComputerUseArgs(driverPath: string): string[] {
  const key = `mcp_servers.${CUA_SERVER_NAME}`;
  return [
    "-c",
    `${key}.command=${tomlString(driverPath)}`,
    "-c",
    `${key}.args=["mcp"]`,
    "-c",
    `${key}.env={CUA_DRIVER_RS_TELEMETRY_ENABLED="0"}`,
  ];
}

/**
 * `v` as a TOML basic string. codex parses the `-c` value as TOML, so a path
 * containing a quote or backslash must be escaped rather than pasted in.
 */
export function tomlString(v: string): string {
  return `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}
