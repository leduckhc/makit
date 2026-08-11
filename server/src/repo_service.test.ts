import { test } from "node:test";
import assert from "node:assert/strict";

import {
  enrichPrs,
  resolveTargetBranch,
  repointVanishedTargets,
} from "./repo_service.js";
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
      targetBranch: "main",
      targetResolved: true,
      retargetedFrom: null,
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

// ─────────────────────────────────────────────────────────────────────────────
// resolveTargetBranch (§0 B3, B6, B7)
//
// One resolver owns precedence, and it must run BEFORE `diffStat` — otherwise
// the pill's numbers come from the persisted value while the label comes from
// the PR, inside a single broadcast.
// ─────────────────────────────────────────────────────────────────────────────

test("resolveTargetBranch: the primary checkout has no target", () => {
  // It is where branches land, not one that lands.
  assert.equal(
    resolveTargetBranch({
      branch: "main",
      isPrimary: true,
      prBaseRefName: "release/1.4",
      persisted: "release/1.4",
      defaultBranch: "main",
    }),
    null,
  );
});

test("resolveTargetBranch: a detached worktree has no target", () => {
  assert.equal(
    resolveTargetBranch({
      branch: null,
      isPrimary: false,
      prBaseRefName: "main",
      persisted: "main",
      defaultBranch: "main",
    }),
    null,
  );
});

test("resolveTargetBranch: an open PR's baseRefName outranks the persisted value", () => {
  // The forge is authoritative while a PR is LIVE — which is also how we inherit
  // GitHub's automatic PR retargeting for free instead of reimplementing it.
  assert.equal(
    resolveTargetBranch({
      branch: "feat/stack-b",
      isPrimary: false,
      prBaseRefName: "main",
      prState: "OPEN",
      persisted: "feat/parent",
      defaultBranch: "main",
    }),
    "main",
  );
});

test("resolveTargetBranch: the persisted value wins when there is no PR", () => {
  assert.equal(
    resolveTargetBranch({
      branch: "feat/stack-b",
      isPrimary: false,
      prBaseRefName: null,
      persisted: "feat/parent",
      defaultBranch: "main",
    }),
    "feat/parent",
  );
});

test("resolveTargetBranch: falls back to the repo default when nothing is stored", () => {
  // B6: this is also the upgrade seed — it reproduces today's behaviour exactly,
  // so shipping the feature moves nobody's numbers until they choose.
  assert.equal(
    resolveTargetBranch({
      branch: "feat/stack-b",
      isPrimary: false,
      prBaseRefName: null,
      persisted: null,
      defaultBranch: "main",
    }),
    "main",
  );
});

test("resolveTargetBranch: a target equal to the worktree's own branch is ignored", () => {
  // Reachable via `renameBranch`, which keeps the path (and therefore the stored
  // target) while changing the branch name. Self-targeting would silently make
  // diffStat report working-tree-only, so fall through instead.
  assert.equal(
    resolveTargetBranch({
      branch: "feat/parent",
      isPrimary: false,
      prBaseRefName: null,
      persisted: "feat/parent",
      defaultBranch: "main",
    }),
    "main",
  );
});

test("resolveTargetBranch: returns null rather than self even via the default", () => {
  assert.equal(
    resolveTargetBranch({
      branch: "main",
      isPrimary: false,
      prBaseRefName: null,
      persisted: null,
      defaultBranch: "main",
    }),
    null,
  );
});

test("resolveTargetBranch: empty strings are treated as unset", () => {
  assert.equal(
    resolveTargetBranch({
      branch: "feat/x",
      isPrimary: false,
      prBaseRefName: "",
      persisted: "",
      defaultBranch: "main",
    }),
    "main",
  );
});

test("resolveTargetBranch: no default and nothing stored yields null", () => {
  assert.equal(
    resolveTargetBranch({
      branch: "feat/x",
      isPrimary: false,
      prBaseRefName: null,
      persisted: null,
      defaultBranch: null,
    }),
    null,
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// B7: PR lifecycle. Only a LIVE pull request is authoritative about where work
// lands — a merged or closed one is history, and letting its base keep
// overriding would pin a worktree to a destination that is already settled.
// ─────────────────────────────────────────────────────────────────────────────

test("resolveTargetBranch: only an OPEN pull request outranks the persisted value", () => {
  const args = {
    branch: "feat/stack-b",
    isPrimary: false,
    persisted: "feat/parent",
    defaultBranch: "main",
  };
  // Live: the forge wins.
  assert.equal(
    resolveTargetBranch({ ...args, prBaseRefName: "main", prState: "OPEN" }),
    "main",
  );
  // Merged/closed: history. The user's own value takes over again.
  assert.equal(
    resolveTargetBranch({ ...args, prBaseRefName: "main", prState: "MERGED" }),
    "feat/parent",
  );
  assert.equal(
    resolveTargetBranch({ ...args, prBaseRefName: "main", prState: "CLOSED" }),
    "feat/parent",
  );
});

test("resolveTargetBranch: an unknown PR state is treated as not authoritative", () => {
  // Forward compatibility: a state this build does not recognise must not be
  // allowed to silently redirect where work lands.
  assert.equal(
    resolveTargetBranch({
      branch: "feat/x",
      isPrimary: false,
      prBaseRefName: "release/9",
      prState: "SOMETHING_NEW",
      persisted: "feat/parent",
      defaultBranch: "main",
    }),
    "feat/parent",
  );
});

test("resolveTargetBranch: state is matched case-insensitively", () => {
  assert.equal(
    resolveTargetBranch({
      branch: "feat/x",
      isPrimary: false,
      prBaseRefName: "main",
      prState: "open",
      persisted: "feat/parent",
      defaultBranch: "main",
    }),
    "main",
  );
});

// repointVanishedTargets — the pure core of the vanished-target repair. Two
// once-live bugs are pinned here: cross-repo corruption and clobbering a
// remote-only PR base.

test("repointVanishedTargets: a genuinely vanished target repoints to the default", () => {
  const writes = repointVanishedTargets({
    here: new Set(["/wt"]),
    persisted: { "/wt": { target: "feat/gone" } },
    live: new Set(["main"]),
    branchTarget: {},
    defaultBranch: "main",
  });
  assert.deepEqual(writes, [{ path: "/wt", target: "main", retargetedFrom: "feat/gone" }]);
});

test("repointVanishedTargets: leaves another repo's persisted target untouched", () => {
  // `/other` belongs to a different repo (not in `here`); its target does not
  // exist among THIS repo's branches, but it must never be rewritten from here.
  const writes = repointVanishedTargets({
    here: new Set(["/wt"]),
    persisted: {
      "/wt": { target: "main" },
      "/other": { target: "some-other-repo-branch" },
    },
    live: new Set(["main"]),
    branchTarget: {},
    defaultBranch: "main",
  });
  assert.deepEqual(writes, [], "no writes: /wt is fine and /other is not ours");
});

test("repointVanishedTargets: a target that exists only on origin is not clobbered", () => {
  // `adoptLivePrTargets` may have just persisted a PR base that lives only on the
  // remote. `live` includes origin branches, so it is NOT treated as vanished.
  const writes = repointVanishedTargets({
    here: new Set(["/wt"]),
    persisted: { "/wt": { target: "release/1.4" } },
    live: new Set(["main", "release/1.4"]),
    branchTarget: {},
    defaultBranch: "main",
  });
  assert.deepEqual(writes, [], "a remote-only base is live, so nothing is repointed");
});

test("repointVanishedTargets: leaves a broken target in place when nothing resolves", () => {
  const writes = repointVanishedTargets({
    here: new Set(["/wt"]),
    persisted: { "/wt": { target: "feat/gone" } },
    live: new Set(["unrelated"]),
    branchTarget: {},
    defaultBranch: null,
  });
  assert.deepEqual(writes, [], "no default to fall back to: surface targetResolved:false instead");
});
