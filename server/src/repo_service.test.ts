import { test } from "node:test";
import assert from "node:assert/strict";

import { enrichPrs } from "./repo_service.js";
import type { GithubGateway, PrLookup } from "./github/gateway.js";
import type { PullRequestDTO, RepoDTO } from "./protocol.js";
import type { PullRequestInfo } from "./git.js";

/** Build a PullRequestInfo with sensible defaults for the fields under test. */
function pr(overrides: Partial<PullRequestInfo> = {}): PullRequestInfo {
  return {
    number: 1,
    url: "https://example.test/1",
    state: "OPEN",
    title: "t",
    isDraft: false,
    mergeable: "MERGEABLE",
    mergeStateStatus: "CLEAN",
    checks: [],
    checkRollup: "none",
    unresolvedComments: 0,
    ...overrides,
  };
}

/** A one-repo git-only snapshot with a single eligible (secondary, branched) worktree. */
function repos(branch: string): RepoDTO[] {
  return [
    {
      id: "r1",
      name: "r1",
      path: "/repo",
      pinned: false,
      lastActivityAt: 0,
      isGitRepo: true,
      defaultBranch: "main",
      currentBranch: "main",
      worktrees: [
        {
          id: "/wt",
          path: "/wt",
          branch,
          isPrimary: false,
          insertions: 0,
          deletions: 0,
          filesChanged: 0,
          uncommittedFiles: 0,
          aheadCount: 0,
          behindCount: 0,
          committedAt: null,
          pr: null,
          sessionIds: [],
        },
      ],
    },
  ];
}

/** A gateway whose only exercised method is prForBranch, returning a canned lookup. */
function gatewayReturning(lookup: PrLookup): GithubGateway {
  return {
    prForBranch: async () => lookup,
  } as unknown as GithubGateway;
}

const worktreePr = (out: RepoDTO[]): PullRequestDTO | null => out[0].worktrees[0].pr;

test("a throttled lookup retains the prior PR and marks it stale", async () => {
  const prior: PullRequestDTO = { ...pr({ number: 42, title: "prior" }) };
  const gateway = gatewayReturning({ kind: "unknown", reason: "throttled" });
  const lastKnown = (_repoPath: string, _branch: string): PullRequestDTO | null => prior;

  const out = await enrichPrs(repos("feature"), gateway, lastKnown);
  const result = worktreePr(out);

  assert.ok(result, "the pill must survive a throttled lookup");
  assert.equal(result!.number, 42);
  assert.equal(result!.stale, true);
});

test("a genuine 'no open PR' clears the pill", async () => {
  const gateway = gatewayReturning({ kind: "none" });
  const lastKnown = (): PullRequestDTO | null => pr({ number: 99 });

  const out = await enrichPrs(repos("feature"), gateway, lastKnown);
  assert.equal(worktreePr(out), null, "a definite 'none' must drop the pill");
});

test("an unknown lookup with no last-known value writes null", async () => {
  const gateway = gatewayReturning({ kind: "unknown", reason: "error" });
  const lastKnown = (): PullRequestDTO | null => null;

  const out = await enrichPrs(repos("feature"), gateway, lastKnown);
  assert.equal(worktreePr(out), null, "nothing to retain → null");
});

test("a fresh PR lookup is written without the stale flag", async () => {
  const gateway = gatewayReturning({ kind: "pr", pr: pr({ number: 7 }) });
  const lastKnown = (): PullRequestDTO | null => null;

  const out = await enrichPrs(repos("feature"), gateway, lastKnown);
  const result = worktreePr(out);

  assert.ok(result);
  assert.equal(result!.number, 7);
  assert.ok(!result!.stale, "a successful re-fetch is not stale");
});
