/**
 * none.ts — the provider for a repository the user told makit to leave alone.
 *
 * Distinct from `unsupported.ts`, and the distinction is the entire reason this
 * file exists: unsupported means *we cannot talk to this forge*, which is a
 * failure worth investigating; `none` means *do not talk to any forge for this
 * repository*, which is an instruction and settled. Collapsing them would make
 * a deliberate choice read as a defect in the UI, and would leave the user with
 * no way to silence PR chatter on a mirror or a vendored copy (SPEC-48 rev 3.2).
 *
 * The observable difference is `prForBranch`:
 *
 *   unsupported → `unknown`  — we did not look, so we cannot claim there is no PR
 *   none        → `none`     — there is nothing to look for, by instruction
 *
 * `unknown` would be wrong here: it makes the app hold a stale PR pill and keep
 * retrying (SPEC-32 §6.5), which is the chatter the user just asked to stop.
 *
 * Makes no requests, spawns no processes, and reads no remote.
 */

import type { OpenPr } from "../git.js";
import type { ForgeGateway, GatewayStats, PrLookup, PrMutation } from "./types.js";

export function createNoForgeGateway(): ForgeGateway {
  return {
    // `none`, not `unknown` — see the module note. This is a conclusion.
    prForBranch: async (): Promise<PrLookup> => ({ kind: "none" }),
    openPrs: async (): Promise<OpenPr[]> => [],
    mutatePr: async (
      _repoPath: string,
      _branch: string,
      _number: number,
      verb: PrMutation,
    ): Promise<{ ok: boolean; error?: string }> => ({
      ok: false,
      // Names the setting, so the fix is one hop away rather than a mystery.
      error: `This repository's Git provider is set to None, so makit cannot run "${verb}" on it. Choose a provider in its Settings section first.`,
    }),
    // Always zero: nothing here spends quota or touches the network, and reporting
    // otherwise would corrupt the call-reduction figure the stats feed.
    stats: (): GatewayStats => ({ execs: 0, exemptExecs: 0, cacheHits: 0 }),
    close: () => {},
  };
}
