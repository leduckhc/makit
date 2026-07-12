/**
 * Agent catalog — the set of agents makit can spawn, surfaced to the app so the
 * user can pick one per session. Availability is probed from the environment
 * (binaries on PATH / bundled deps). Pure + dependency-light so it's unit
 * testable and cheap to call on demand.
 */

import { existsSync } from "node:fs";
import { delimiter, join } from "node:path";

export type AgentTransport = "native" | "acp";

export interface AgentDescriptor {
  /** Stable id used on the wire + in spawn requests. */
  id: string;
  /** Human label for the picker. */
  label: string;
  transport: AgentTransport;
  /** Whether the backing binary/dep is present on this machine. */
  available: boolean;
}

/** True if `cmd` is an absolute/relative existing file or resolves on PATH. */
export function onPath(cmd: string): boolean {
  if (cmd.includes("/") || cmd.includes("\\")) return existsSync(cmd);
  const dirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
  const exts = process.platform === "win32" ? ["", ".exe", ".cmd", ".bat"] : [""];
  for (const dir of dirs) {
    for (const ext of exts) if (existsSync(join(dir, cmd + ext))) return true;
  }
  return false;
}

function piNativeAvailable(): boolean {
  return onPath(process.env.MAKIT_PI_BIN || "pi");
}

/** Resolve the codex-acp binary if one is available (env override or PATH). */
export function codexAcpBin(): string | undefined {
  const override = process.env.MAKIT_CODEX_ACP_BIN;
  if (override && (existsSync(override) || onPath(override))) return override;
  if (onPath("codex-acp")) return "codex-acp";
  return undefined;
}

/**
 * List the agents this makit host can offer. Native pi is always listed; Codex
 * variants are listed only when their respective binary is detected.
 */
export function listAgents(): AgentDescriptor[] {
  const agents: AgentDescriptor[] = [
    { id: "pi", label: "Pi (native)", transport: "native", available: piNativeAvailable() },
  ];
  if (codexAcpBin()) {
    agents.push({ id: "codex", label: "Codex (ACP)", transport: "acp", available: true });
  }
  // Native codex app-server path (first-party JSON-RPC), when codex is installed.
  if (onPath(process.env.MAKIT_CODEX_BIN || "codex")) {
    agents.push({ id: "codex-native", label: "Codex (app-server)", transport: "native", available: true });
  }
  return agents;
}

/** Transport for a given agent id (defaults to native for the built-in pi). */
export function transportFor(agentId: string): AgentTransport {
  return agentId === "codex" ? "acp" : "native";
}
