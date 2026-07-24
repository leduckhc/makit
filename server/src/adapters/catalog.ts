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
    agents.push({ id: "pi", label: "Pi (ACP)", transport: "acp", available: true });
  }
  // Native codex app-server path (first-party JSON-RPC), when codex is installed.
  if (onPath(process.env.MAKIT_CODEX_BIN || "codex")) {
    agents.push({ id: "codex", label: "Codex (app-server)", transport: "native", available: true });
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
