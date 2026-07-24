/**
 * AgentFactory: construct the concrete {@link AgentAdapter} for an agent id.
 *
 * Extracted from {@link SessionManager} (SPEC-19) so adapter selection lives
 * in one place rather than inline in the manager's spawn/attach paths. Pure —
 * no manager state.
 */

import type { AgentAdapter } from "./adapters/adapter.js";
import { AcpAdapter } from "./adapters/acp.js";
import { CodexAppServerAdapter } from "./adapters/codex.js";

/**
 * The `pi-acp` bridge binary makit wraps pi with — it speaks ACP JSON-RPC over
 * stdio and spawns `pi --mode rpc` itself (svkozak/pi-acp). Overridable for
 * tests / non-standard installs.
 */
function piAcpBin(): string {
  return process.env.MAKIT_PI_ACP_BIN || "pi-acp";
}

/**
 * Construct the adapter for an agent id.
 *
 * - `pi` runs over ACP: makit wraps it with the `pi-acp` bridge (no args — the
 *   bridge spawns `pi --mode rpc` itself), driven through {@link AcpAdapter}.
 * - `codex` runs native via `codex app-server` ({@link CodexAppServerAdapter}).
 *   `codex-native` is a back-compat alias for sessions persisted before the id
 *   was folded into `codex` (SPEC-27).
 */
export function buildAdapter(agentId: string): { agent: string; adapter: AgentAdapter } {
  switch (agentId) {
    case "codex":
    case "codex-native":
      return { agent: "codex", adapter: new CodexAppServerAdapter() };
    case "pi":
    default:
      return {
        agent: "pi",
        adapter: new AcpAdapter({ spec: { agent: "pi", command: piAcpBin(), args: [] } }),
      };
  }
}
