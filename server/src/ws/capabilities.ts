/**
 * The command capability map (SPEC-46 D17 / contract C1).
 *
 * Default-deny. Each registered command kind maps to the **agent** caps that
 * may dispatch it; `[]` means "no agent cap grants this — a `client` or
 * full-access principal only". A full-access principal (an existing phone, no
 * caps) and a `client` principal (`cli@<host>`) may dispatch everything; the
 * three agent caps carve out the narrow surface a handoff child needs:
 *
 *  - `read`  → `sub`, `unsub`, `session.transcript`, `sessions.snapshot`
 *              (none are router commands: sub/unsub are handled before the
 *              router, sessions.snapshot is push-only, session.transcript is
 *              not registered yet — so `read` grants no `cmd` today, by design).
 *  - `send`  → `send.message`, `session.action`.
 *  - `spawn` → `session.spawn`, `worktree.create`.
 *
 * Everything else — `session.kill`, `session.archive`, `session.setAgent`,
 * `ports.*`, `pr.*`, `worktree.wrapUp`/`discard`, `devices.*` — is refused for
 * an agent token. Completeness is enforced by a test over `router.kinds()`, so
 * a command added later without a map entry fails the build rather than
 * silently becoming agent-reachable.
 */

import type { DeviceCap } from "../protocol.js";
import type { Principal } from "./principal.js";
import { isFullAccess } from "./principal.js";

export const COMMAND_CAPABILITIES: Record<string, readonly DeviceCap[]> = {
  // send
  "send.message": ["send"],
  "session.action": ["send"],
  // spawn
  "session.spawn": ["spawn"],
  "worktree.create": ["spawn"],
  // client / full-access only (no agent cap grants these)
  "agents.list": [],
  "agents.refresh": [],
  "branch.rename": [],
  cancel: [],
  "client.log": [],
  "github.pause": [],
  "github.refresh": [],
  "github.watch": [],
  "metrics.watch": [],
  "ports.watch": [],
  "pr.list": [],
  "pr.markReady": [],
  "pr.updateBranch": [],
  "pr.squashMerge": [],
  "project.add": [],
  "project.browse": [],
  "project.remove": [],
  "push.register": [],
  "queue.cancel": [],
  "queue.promote": [],
  "queue.reorder": [],
  "queue.update": [],
  "repo.refresh": [],
  "session.archive": [],
  "session.attach": [],
  "session.kill": [],
  "session.list": [],
  "session.listArchived": [],
  "session.setAgent": [],
  "session.unarchive": [],
  "worktree.createFromPr": [],
  "worktree.discard": [],
  "worktree.remove": [],
  "worktree.wrapUp": [],
  // dev-only (registered only under MAKIT_DEV) — mapped so completeness holds
  // even when they are present.
  "debug.ask": [],
  "debug.ask-multi": [],
};

/**
 * True when `principal` may dispatch `kind`. Full access and `client` pass
 * everything; an agent token passes only when it holds a cap the map lists for
 * that kind. An unmapped kind is denied for anything less than full access.
 */
export function canDispatch(kind: string, principal: Principal | undefined): boolean {
  if (isFullAccess(principal)) return true;
  const caps = principal!.caps!;
  if (caps.includes("client")) return true;
  const allowed = COMMAND_CAPABILITIES[kind];
  if (allowed === undefined) return false;
  return allowed.some((cap) => caps.includes(cap));
}
