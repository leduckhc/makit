/**
 * AgentFactory: construct the concrete {@link AgentAdapter} for an agent id.
 *
 * Extracted from {@link SessionManager} (SPEC-19) so adapter selection lives
 * in one place rather than inline in the manager's spawn/attach paths. Pure —
 * no manager state.
 */

import type { AgentAdapter } from "./adapters/adapter.js";
import { PiAdapter } from "./adapters/pi.js";
import { AcpAdapter, codexAcpSpec } from "./adapters/acp.js";
import { CodexAppServerAdapter } from "./adapters/codex.js";

/** Construct the adapter for an agent id. */
export function buildAdapter(agentId: string): { agent: string; adapter: AgentAdapter } {
  switch (agentId) {
    case "codex":
      return { agent: "codex", adapter: new AcpAdapter({ spec: codexAcpSpec() }) };
    case "codex-native":
      return { agent: "codex-native", adapter: new CodexAppServerAdapter() };
    case "pi":
    default:
      return { agent: "pi", adapter: new PiAdapter() };
  }
}
