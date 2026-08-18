/**
 * One rule for "may this principal read this session?" (SPEC-cli-as-client D17).
 *
 * It lives in its own module because four separate paths reach session data —
 * `fanout`, `handleSub`, the `sessions.snapshot` pushed on auth, and
 * `session.transcript` — and the original implementation gated only the first.
 * A rule duplicated four times is a rule that will diverge four ways; the
 * accompanying test enumerates the call sites so a fifth path cannot quietly
 * appear without a decision.
 *
 * The rule itself: a **human** principal (a phone with no caps, or the CLI's
 * `client` cap) reads everything, exactly as before SPEC-cli-as-client — nothing here may
 * narrow what already-paired devices can see. A **session-scoped** principal (an
 * agent token, D3) reads its own session and its **descendants**: an agent that
 * handed work off to a child is entitled to watch what it started, but not its
 * parent's work and not a stranger's.
 */
import { isAgentScoped, type Principal } from "./principal.js";

/** Longest lineage chain we will walk before treating the data as hostile. */
const MAX_WALK = 64;

/**
 * Whether `principal` may read `sessionId`.
 *
 * `parentOf` resolves a session's parent from persisted lineage; it is injected
 * so this stays pure and testable, and so the walk terminates on the forged
 * cycles that persisted data can contain (a crash mid-write, a hand-edited
 * database) rather than looping forever inside a socket handler.
 */
export function canReadSession(
  principal: Principal | undefined,
  sessionId: string,
  parentOf: (sessionId: string) => string | undefined,
): boolean {
  if (!isAgentScoped(principal)) return true; // human: unchanged, full access
  const own = principal!.sessionId!;
  if (sessionId === own) return true;
  // Climb from the target towards the root: reachable means `own` is an ancestor,
  // i.e. the target is a descendant of the agent's own session.
  const seen = new Set<string>([sessionId]);
  let current = parentOf(sessionId);
  for (let i = 0; current !== undefined && i < MAX_WALK; i++) {
    if (current === own) return true;
    if (seen.has(current)) break; // forged cycle
    seen.add(current);
    current = parentOf(current);
  }
  return false;
}
