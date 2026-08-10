/**
 * unsupported.ts — the provider for a forge makit cannot talk to.
 *
 * Exists so an unsupported forge fails HONESTLY and CHEAPLY. Before detection,
 * a GitLab or Bitbucket remote was routed to the Forgejo provider, where every
 * poll spent a real HTTP request to an API that does not exist there and came
 * back as `unknown` — the same result as a Forgejo instance being down, so the
 * user had no way to tell "makit doesn't support this" from "the network is
 * broken".
 *
 * This makes no requests at all, and a mutation says what is actually wrong.
 */

import type { OpenPr } from "../git.js";
import type { ForgeGateway, ForgeSoftwareName, GatewayStats, PrLookup, PrMutation } from "./types.js";

export interface UnsupportedGatewayDeps {
  /** What the detector found, for the message. */
  software?: () => ForgeSoftwareName;
}

/** Human name for the message; `unknown` gets a vaguer phrasing. */
function describe(software: ForgeSoftwareName): string {
  switch (software) {
    case "gitlab":
      return "GitLab";
    case "unknown":
      return "this forge";
    default:
      return software;
  }
}

export function createUnsupportedGateway(deps: UnsupportedGatewayDeps = {}): ForgeGateway {
  const stats: GatewayStats = { execs: 0, exemptExecs: 0, cacheHits: 0 };
  const name = (): string => describe(deps.software?.() ?? "unknown");

  return {
    // `unknown`, never `none`: we did not look, so we cannot claim there is no PR.
    prForBranch: async (): Promise<PrLookup> => ({ kind: "unknown", reason: "error" }),
    openPrs: async (): Promise<OpenPr[]> => [],
    mutatePr: async (
      _repoPath: string,
      _branch: string,
      _number: number,
      verb: PrMutation,
    ): Promise<{ ok: boolean; error?: string }> => ({
      ok: false,
      error: `makit has no ${name()} provider yet, so it cannot run "${verb}" on this repository.`,
    }),
    stats: () => ({ ...stats }),
    close: () => {},
  };
}
