---
name: "makit-add-forge-provider"
description: "Add or debug a non-GitHub forge provider (Forgejo/Gitea) in makit's server, including the Forgejo API hazards that silently corrupt PR signals."
---
## When to Use
Use when adding, changing, or debugging a forge provider other than GitHub in makit (server/src/forge/**), when a PR pill shows the wrong glyph or flickers to unknown on a non-GitHub remote, or when deciding whether to shell out to a forge CLI versus calling REST directly.

## Procedure
1. Download the instance's own swagger first: curl https://<host>/swagger.v1.json. It reports the real version (e.g. 'Forgejo API 16.0.0-dev-668+gitea-1.22.0') and is authoritative over any docs or CLI README. Query it with jq rather than reading it.
2. Do NOT shell out to a forge CLI for daemon data. tea's `-o json` is a stringly-typed projection of its rendered table (modules/print/table.go builds map[string]string over a fixed PullFields allowlist that omits draft, merged and head sha, and rewrites mergeable as Mergeable&&open). Call REST directly from TypeScript instead.
3. Implement pure mapping first in server/src/forge/<provider>/map.ts (URL builders + payload adapters, no I/O), TDD'd. Every API hazard belongs here so it is reachable by `node --test`.
4. Implement the gateway in server/src/forge/<provider>/gateway.ts against an injectable Http seam that NEVER rejects (status 0 = transport failure), mirroring the Exec seam in github/gateway.ts. Test with a scripted route table, not real network.
5. Segregate the interface: ForgeGateway (prForBranch/openPrs/mutatePr/stats/close) vs BudgetReporting (GitHub-only). Forgejo has no rate_limit endpoint and no rate-limit headers, so it must not fake a budget. Guard budget wiring with hasBudgetReporting().
6. Verify against a REAL instance with createFetchHttp before believing any of it. Fixtures agree with your assumptions; real instances do not. codeberg.org is a public Forgejo suitable for read-only checks.
7. Wire provider selection at the single construction point manager.ts:199 (`createGithubGateway({exec: run})`), keyed off the origin remote host. Consumers (git.ts, repo_service.ts, ws/commands/deps.ts) depend only on the interface and need no change.
8. Guard the budget call sites when a non-GitHub provider can be selected: server.ts (~lines 275, 283-284, 303, 348, 361) and ws/commands/github.ts (~lines 25, 32).

## Pitfalls
- A per-repo provider setting that is persisted and rendered is NOT wired. Check every consumer: makit had `provider`, `defaultBranch` and `logoHue` all stored, served on the DTO, parsed by the app -- and read by nothing. Grep for the field name outside the store/DTO layer; if the only hits are the write and the parse, it is ornamental.
- The forge router caches its gateway choice per repo path. If the cache key does not include the user's provider override, changing the setting appears to do nothing until the daemon restarts -- indistinguishable from a broken feature. Key on `{path, choice}` and re-route when the choice changes, but keep the cache when it has not (the home-screen fan-out depends on sharing one `git remote` read).
- Honour an override WITHOUT probing the instance. The cases an override exists for are exactly the ones where detection cannot answer (a private instance that 401s an anonymous request; one behind a proxy hiding `/api/forgejo/v1/version`), so spending the probe delays every poll to learn nothing.
- 'No forge by choice' and 'a forge we cannot talk to' must be different gateways. Unsupported answers `unknown` (we did not look, so we cannot claim there is no PR); a user-chosen `none` must answer `none`. Returning `unknown` for `none` makes the app hold a stale PR pill and keep retrying -- the exact chatter the setting exists to stop.
- Do not derive `hasRemote` from `forge !== undefined`. Those two facts have THREE states between them -- not measured yet, no remote, a forge identified -- and one boolean cannot hold three. Deriving it made every un-polled repo claim to have no origin and rendered the app's 'not identified yet' wording unreachable.
- PR *listing* routes through the gateway automatically, so a Forgejo picker looks fixed while the flow is broken halfway: `addWorktreeForPr` ran `gh pr checkout` unconditionally. Forgejo/Gitea publish PR heads at `refs/pull/<n>/head` -- use that (it exists for fork PRs too, whose branch is not on `origin`), and keep `gh` for GitHub rather than replacing a path that already handles forks and push tracking.
- When comparing repo paths for 'same directory', canonicalise BOTH sides. On macOS `/tmp/x` and `/private/tmp/x` are one place, and a project restored from `projects.json` holds whichever spelling was written -- so a duplicate-path check comparing canonical against raw silently passes.
- Repo-path validation is NOT worktree-root validation. A worktree root may not exist yet (it is created on demand) and must be inside `$HOME` (prune DELETES under it). A repo path must already exist and must NOT be confined to `$HOME` -- a checkout on an external volume is ordinary, and makit never deletes a repo path.
- Check whether another agent is editing the same worktree before a long TDD run. A parallel attempt added a private `_checkoutStrategyFor` plus a non-compiling probe mid-session; two implementations in one file break each other. `git status` between commits catches it.
## Verification
1. cd server && pnpm exec tsc -p . --noEmit
2. cd server && node --import tsx --test "src/**/*.test.ts" "test/**/*.test.ts" -- must be fully green (1331 tests after the forge router landed).
3. cd app && flutter analyze --no-pub -- must report no issues.
4. cd app && flutter test --no-pub: BASELINE IS NOT ZERO. Clean HEAD fails ~23 with 'loading <file> [E]' errors, and the failing SET CHANGES BETWEEN RUNS (15/17/23) -- it is flaky load pressure, not your change. Lowering --concurrency does NOT fix it. Before blaming a diff, git stash push -u -- app, run the same command, compare counts, then git stash pop. Verify individual affected test files instead; they pass in isolation.
5. Run the provider against a real instance via createFetchHttp, and the whole chain via createDefaultForgeGateway in a temp repo with a real remote (git init + git remote add origin https://codeberg.org/forgejo/forgejo.git): a branch with a PR must return kind='pr', a nonexistent branch kind='none', an unreachable host kind='unknown' (never 'none').
6. Cross-check the computed checkRollup against the server's own combined-status `state` field -- they should agree.
7. scripts/sync-icons.sh --check must pass (vendored glyphs match phosphor_extras).
8. bash -n scripts/forge, then trace dispatch with a fake tea/gh on PATH in a temp repo with the relevant origin remote.
