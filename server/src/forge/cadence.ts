/**
 * cadence.ts — how often to re-poll pull requests, across providers.
 *
 * GitHub's degradation ladder (`github/policy.ts`) exists to ration a quota.
 * Forgejo has no quota: no `/api/v1/rate_limit` endpoint, no rate-limit response
 * headers, and no request limiter anywhere in its configuration. So a
 * Forgejo-only setup must not be governed by that ladder.
 *
 * It previously was, and the failure was silent: with no GitHub repo the
 * `rate_limit` read never succeeds, the level stays `unknown`, and the ladder
 * treats unknown as the warm rung — 30s polling with unresolved counts shed.
 * Forgejo repos were therefore polled 6x slower than needed against a quota that
 * provably does not exist.
 *
 * KNOWN LIMITATION: `pr_watcher` runs one global timer, so a MIXED setup (GitHub
 * and Forgejo repos together) still takes the GitHub cadence for everything.
 * Fixing that properly means per-repo cadence in the watcher; conflating it here
 * would be worse, because taking the fast rung in a mixed setup would burn the
 * GitHub quota the ladder is protecting.
 */

import type { GithubGateway } from "../github/gateway.js";
import { POLL_FAST_MS, decide } from "../github/policy.js";
import { hasProviderMix } from "./types.js";

/**
 * The poll interval to use now.
 *
 * Takes the unthrottled rung only when the providers in play are KNOWN and
 * exclude GitHub. An empty mix means "nothing routed yet", not "no GitHub" —
 * guessing fast there would spend GitHub quota for the first ticks after startup.
 */
export function forgePollIntervalMs(gateway: GithubGateway): number {
  if (hasProviderMix(gateway)) {
    const inUse = gateway.providersInUse();
    if (inUse.size > 0 && !inUse.has("github")) return POLL_FAST_MS;
  }
  return decide(gateway.budget()).pollIntervalMs;
}
