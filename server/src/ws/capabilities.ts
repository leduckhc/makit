/**
 * The agent capability surface (SPEC-46 D17 / contract C1).
 *
 * Default-deny: every command kind is forbidden to agent tokens unless
 * explicitly listed here. The map is indexed by agent cap (`send`, `spawn`,
 * `read`) and lists the command kinds that cap grants.
 *
 * A full-access principal (phone, no caps) and a `client` principal
 * (`cli@<host>`) may dispatch everything; the three agent caps carve out the
 * narrow surface a handoff child needs:
 *
 *  - `send`  → `send.message`, `session.action`
 *  - `spawn` → `session.spawn`, `worktree.create`
 *  - `read`  → `session.transcript`
 *
 * All other commands — `session.kill`, `session.close`, `session.setAgent`,
 * `ports.*`, `pr.*`, `worktree.wrapUp`/`discard`, `devices.*` — are
 * client/full-access only.
 *
 * Completeness is enforced by a test over `router.kinds()`: a command added
 * later without an entry here is caught as unmapped, and `canDispatch` denies
 * it for agent tokens, not silently permits it.
 */

import type { DeviceCap } from "../protocol.js";
import type { Principal } from "./principal.js";
import { isFullAccess } from "./principal.js";

/** Commands reachable by each agent cap. Everything else is client/full-access only. */
const AGENT_COMMANDS: Record<DeviceCap, string[]> = {
  send: ["send.message", "session.action"],
  spawn: ["session.spawn", "worktree.create"],
  read: ["session.transcript"],
  client: [], // not an agent cap; listed for completeness
};

/**
 * True when `principal` may dispatch `kind`. Full access and `client` pass
 * everything; an agent token passes only when that cap grants the command.
 * An unmapped kind is denied for anything less than full access.
 */
export function canDispatch(kind: string, principal: Principal | undefined): boolean {
  if (isFullAccess(principal)) return true;
  const caps = principal!.caps!;
  if (caps.includes("client")) return true;
  // An agent token passes iff one of its caps lists this command
  for (const cap of caps) {
    if (AGENT_COMMANDS[cap as DeviceCap]?.includes(kind)) return true;
  }
  return false;
}
