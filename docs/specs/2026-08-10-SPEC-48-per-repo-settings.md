# SPEC-48 — Per-repo settings: one Settings section per repository

**Status:** P2 Implemented (rev 3.2) · **Priority:** P2 · **Branch:** `feat/forgejo-git-provider`
**Depends on:** SPEC-11 (repo-centric home — `RepoDTO`, `repos.snapshot`, the repo card and its
`dotsThree` menu), SPEC-19 (`SettingsResetButton` as the one shared "reset to default" widget, and
`SettingsGroup` as the grouped-list idiom), and the forge-detection work already on this branch
(`server/src/forge/detect.ts`, `router.ts`, commits `53be5e26`/`164eda8e`/`87a0883c`).
**Design board:** [`mockups/repo-settings.html`](../../mockups/repo-settings.html) (the section, the
inheritance model, the script trust decisions) and
[`mockups/forge-provider-per-repo.html`](../../mockups/forge-provider-per-repo.html) (where the forge
surfaces outside Settings). Both are kept as separate boards on purpose.

---

## Goal

A repository in makit currently has **no configurable state at all**. Everything that varies is either
global (`MAKIT_WORKTREE_DIR` at `git.ts:33`), environmental (`FORGEJO_ACCESS_TOKEN`), or derived
(`defaultBranch` from `origin/HEAD`). The moment a second repo wants a different worktree root, or a
different post-create step, there is nowhere to put it.

This spec adds that place: **one Settings section per repository**, and — more importantly — the
*inheritance model* those sections render. The model is the feature; the rows are its first four
tenants.

| Question a user has | Answered by |
| --- | --- |
| "which forge is this on, and am I authenticated?" | the Git provider row, **detected**, never asked (D3) |
| "where will a new worktree land?" | Worktree root, showing the **effective** value and its source (D5) |
| "why is this repo different from my others?" | any row badged `overridden` (D6) |
| "run `pnpm install` after every worktree create" | a lifecycle script — **P3, and gated** (D12, D13) |

## What already exists, and is reused rather than rebuilt

Half of this is committed. Naming it here so the plan does not re-invent it.

| Need | Already in the repo | Consequence |
| --- | --- | --- |
| Per-project persistence | `server/src/project-store.ts` → `$MAKIT_HOME/projects.json`, documented to degrade to `[]` on a corrupt file so the daemon always starts | P2 extends `PersistedProject`; no new store, no new file |
| Stable per-repo key | `PersistedProject.id` (random handle, survives restart, leaks nothing about the filesystem) | settings key off `id`, never off the path |
| Grouped rows + reset | `SettingsGroup`, `SettingsSectionHeader`, `SettingsResetButton` — the last already collapses to a fixed-width box so rows with and without an override stay aligned | the inheritance affordance is a relabel, not a new widget |
| Forge identity | `forge/detect.ts` (probes `/api/forgejo/v1/version`, `/api/v1/version`, `/api/v4/version`; cached per host; verified against four live forges) | the provider row is a read-out |
| Which repos are "mine" | `pinned:true` for projects restored from `projects.json` (`manager.ts:215`) vs `pinned:false` for ad-hoc `addProject` (`manager.ts:287`) | bounds the sidebar (D2) |
| Command plumbing | `server/src/ws/commands/*` + `ws/commands/deps.ts` | P2 adds one command file |
| Effective worktree root | `git.ts:33` — `process.env.MAKIT_WORKTREE_DIR ?? join(homedir(), ".worktrees")`, the **only** consumer | P1 reports it; P2 routes it through the resolver |

## Why the UI ships first, and why that is not a fake

The requested order is UI-first. That is achievable **without stub data**, because every row in the
mockup already has a real source:

| Row | P1 source | Real? |
| --- | --- | --- |
| Logo | monogram derived from `RepoDTO.name` — pure, client-side | yes |
| Root path | `RepoDTO.path` | yes |
| Git provider | new `RepoDTO.forge` (one field, fed by `detect.ts`) | yes |
| Default branch | `RepoDTO.defaultBranch` | yes |
| Worktree root | new `RepoDTO.worktreeRoot` — the **effective global** value | yes |
| Branch prefix | *not rendered in P1* — it has no source until P2 (D9) | — |
| Lifecycle scripts | rendered as a disabled group reading `Not set` (D12) | yes (it is genuinely not set) |

So P1 is pixel-complete against the mockup minus one row, every value is measured, and every badge is
true: `detected`, `from remote`, `from name`, `inherited`. Nothing says `overridden` because in P1
nothing *can* be overridden — which is the honest rendering, not a placeholder.

## Decisions (locked before implementation)

| # | Decision | Why |
| --- | --- | --- |
| **D1** | **One sidebar section per repository**, under a `REPOSITORIES` group header, after `About`. Not a single "Repositories" page with a list→detail drill. | Fixed app sections are a closed taxonomy; repos are data. Grouped, this is the Mail/Finder idiom, and it removes a navigation level — the section title *is* the repo name, so no breadcrumb. |
| **D2** | Only `pinned:true` projects get a section. | Bounds the sidebar by what the user added (3 on a real install) rather than by what makit noticed. Prevents the settings sidebar becoming a file browser. |
| **D3** | The Git provider row is a **read-out with no P1 control**. Detection is authoritative; the override is P2 and lives behind the same segmented control the Endpoint row uses (`Auto | Forgejo | Gitea | GitHub`), with `Auto` selected and its resolved value described beneath. | Detection is correct for every forge tested. Asking the user to answer what the server already knows is friction on the majority path. The segmented-plus-description idiom is already in Settings (Endpoint: `Auto: Tailscale if available, else loopback`). |
| **D4** | Root path is **displayed, not editable**, with a copy affordance. | The path is the repo's identity in `projects.json`; changing it is remove-and-re-add, which the repo card menu already offers. |
| **D5** | Every inheritable row renders the **effective value** plus a badge naming its source. Never an empty field that silently means a default. | A blank "Worktree root" that means `~/.worktrees` is how worktrees end up somewhere unexpected. |
| **D6** | Badge vocabulary is closed: `detected`, `from remote`, `from name`, `inherited`, `from environment`, `overridden`. `overridden` is the **only** state with a visible `SettingsResetButton`. | One vocabulary, one undo target. |
| **D7** | Reset means **"inherit again"**, not "copy today's global". | So a later change to the global still propagates. Storing the resolved value at reset time is a silent fork. |
| **D8** | Resolution order, per setting, first hit wins: `repo override → global setting → env var → built-in default`. Env vars are a **source in the chain**, rendered `from environment` and read-only. | `MAKIT_WORKTREE_DIR` must keep working; the app cannot change the daemon's environment, so it must not pretend to. |
| **D9** | P1 renders **only rows with a P1 source**. Branch prefix is deferred to P2 rather than shown disabled. | A row that exists but can never do anything is worse than an absent one; it invites a bug report. |
| **D10** | Per-repo settings are **server-owned** (`projects.json`), never `SharedPreferences`. | The daemon consumes them (worktree root, hooks), and app-side prefs are per-device — a value set on a phone would never reach the daemon that creates the worktree, and two paired devices would disagree. |
| **D11** | Unknown keys in a persisted `settings` object are **preserved on save**. | An older daemon paired with a newer app must not silently drop a field it does not understand. |
| **D12** | **P1 and P2 ship no script execution.** The group renders, disabled, reading `Not set`; on iOS it reads `Editable on the host only`. | The rows communicate the shape without creating the surface. |
| **D13** | **P3 is gated on two security decisions, recorded here before any code:** (a) script text lives in makit's own config and is **never read from the repository working tree**; (b) **only the host may set one** — a paired device may read but not write. | (a) Otherwise `git clone` + add-to-makit is arbitrary code execution, and reviewing a stranger's PR branch runs their script. (b) makit pairs with phones; if any paired device can write a script the daemon executes, pairing stops meaning "chat with an agent" and starts meaning "remote shell on my laptop". Neither is recoverable by a later patch. |
| **D14** | Logo is a **deterministic monogram** from the repo name (stable hue), with a custom image deferred to P4. | Zero state, identical on every device, and it makes the sidebar group scannable. A custom image is a byte-transfer path with size/type validation, not a settings row. |
| **D15** | The sidebar is the **second** place listing repos. Both it and the repo-centric home render from the same `RepoDTO` and the same monogram widget. | Two independent lists drift in order, name and logo. The mitigation is a shared source, not a convention. |

## What P1 does not do

- No writes. Nothing on the P1 page is editable; there is no `repo.settings.set`.
- No `settings` object in `projects.json` yet — P1 adds **no persistence at all**.
- No branch prefix row (D9), no custom logo image (D14), no script execution (D12).
- No GitLab provider. Detection *names* GitLab; supporting it is a separate implementation
  (`merge_requests`, different auth) and explicitly out of scope for every phase here.
- No overflow rule for many repos. Past ~10, keep pinned inline and add one `All repositories…`
  entry — cheap later precisely because `pinned` exists, and 3 sections is not a scrolling problem.

## Phasing

| Phase | Contents | Gate to start |
| --- | --- | --- |
| **P1** | `RepoDTO.forge` + `RepoDTO.worktreeRoot`; the Settings section, read-only, pixel-audited against the mockup; monogram widget; `Settings…` entry in the repo card menu; widget + integration tests; real-app verification | spec+plan reviewed |
| **P2** | `PersistedProject.settings`, the resolver, `repo.settings.get/set`, editable rows (worktree root, branch prefix, provider override), `git.ts:33` routed through the resolver | P1 shipped and verified |
| **P3** | Lifecycle scripts: runner with allowlisted env, cwd, timeout, pre-prune veto, host-only writes | **D13 (a) and (b) explicitly confirmed** |
| **P4** | Custom logo image upload; `All repositories…` overflow | demand |

## Verification

P1 is not "the tests pass". It is, in order:

1. `cd server && pnpm exec tsc -p . --noEmit` clean; `node --import tsx --test` all-green with the
   pre-existing count preserved (1380 at spec time).
2. `cd app && flutter analyze --no-pub` reports no issues; `flutter test --no-pub` green **judged
   against the known flake baseline** — `loading <file> [E]` failures are random and present at HEAD
   (~15–23 per run, every file passes alone). Judge by non-loading failures and by whether a file
   fails in *all* runs.
3. Every new test's bite proven by reverting only the production line and watching it fail.
4. **Pixel audit against `mockups/repo-settings.html`**: the built section screenshotted from the real
   macOS app and compared to the mockup card, row by row — green uppercase group headers, two-line
   rows, badge placement, trailing reset slot alignment.
5. **The real app, opened and driven** (not a widget test): Settings → the repo section, on macOS.
6. An integration test in `app/integration_test/` that reaches the section and asserts the rows.

## Non-goals

Global settings redesign. Repo add/remove flows. Anything that writes to the repository working tree.
A settings-sync mechanism between paired devices. Per-worktree (as opposed to per-repo) settings.


---

## Review round 1 — both reviewers returned NOT READY

Two parallel `codex exec` reviews (technical correctness; engineering practice). Every finding below
was **re-verified against the code by hand** before being accepted — the reviewers' verdicts are not
taken on trust.

### Confirmed wrong in rev 1

| # | Claim in rev 1 | Reality |
| --- | --- | --- |
| R1 | T1.1's fixture edit is a RED test | **Vacuous.** `contract.test.ts:24` loads snapshots as `Record<string, unknown>[]` and only asserts codec round-trip; `decodeFrame` (`codec.ts:104`) validates `v`/`t`/`id` and then casts. A new `RepoDTO` field can never fail it. |
| R2 | `createForgeRouter` already records per-repo decisions | **False.** `router.ts:165` caches `Map<string, Promise<ForgeGateway>>` only — no software, host or auth is retained. `softwareFor` needs a new decision record, not an accessor. |
| R3 | A previous `softwareFor` was reverted for not being on the declared type | **Unsubstantiated.** It happened in an uncommitted edit, so `git log -S softwareFor` finds nothing. Claim removed. |
| R4 | `repo_service.ts` can reach the router | **False.** `listRepos` takes `GithubGateway` (`repo_service.ts:62`) and `manager._gateway` is typed the same (`manager.ts:187`); a router-only accessor is invisible across that boundary. |
| R5 | `git.ts:33` is the only consumer of the worktree root | **Only of the env read.** The resolved root is consumed by `addWorktree` (`git.ts:468`), `addWorktreeForPr` (`git.ts:585`) and `uniqueWorktreeDir` (`manager.ts:1006`). P2 must route all three or collision checks and creation disagree. |
| R6 | The Settings sidebar can take a new group | **Foundational work missing.** `kSettingsSections` is a static `final List` (`settings_registry.dart:24`) carrying `SettingsItem` search entries, resolved statically by `settings_window.dart`. Dynamic repo sections need `sectionsFor(repos)`, stable ids, generated search entries, and defined behaviour when a selected repo disappears. |
| R7 | T4.1 adds the entry point | **Wrong surface.** `RepoCard` is used only by the *mobile* `home_screen.dart:53`; desktop Settings is a separate window whose open state is a bare `bool` (`window_overlays.dart:28`) and whose `_openSettings()` takes no repo id. There is no deep-link path to carry a `repoId`. |
| R8 | T2.3 is red today | **Cannot compile.** `PrDetailBody` receives `PrStatus`/`PullRequest`, not a repo (`pr_detail.dart:77`), so there is no server-forge input to disagree with the URL. |
| R9 | T5.1 uses the right harness | **Wrong one.** `app/tool/e2e-desktop.sh` runs `control_e2e_test.dart`, which pumps `ServerDevicesSection` directly and serves no `repos.snapshot`. |
| R10 | D11 "unknown keys preserved" | **Not true today and not free.** `project-store.ts:81`/`:99` reconstruct and emit only `{id, path}`, and `manager.ts:204` copies only those into `ProjectDTO`. Lossless `settings` needs work in all three places. |
| R11 | `forge` will be populated for every repo | **May never be.** Routing happens only when a gateway PR op calls `pick`; a repo with no eligible worktree is never routed. `forge` must be modelled as genuinely *pending*, or detection must be driven proactively for the snapshot. |

### The finding that changes the product, not the plan

**Write authorization was specified for scripts (D13) and for nothing else.** A paired device that can
set an arbitrary `worktreeRoot` directs host filesystem operations at a path of its choosing. That is a
security surface of the same kind as D13(b), and rev 1 left it undecided. Rev 2 must state who may write
each setting, and what path validation applies (absolute? canonicalised? symlink-checked? denied
outside `$HOME`?).

### Accepted YAGNI cuts

Disabled Lifecycle Scripts group in P1; the six-value badge vocabulary as one abstraction (provenance
and resolution are different things); the generic four-level resolver (there is no global settings
store — the real chain is `repo override → env → default`); provider and default-branch overrides;
the copy button; two-line rows as a blanket rule; the monogram's hue-determinism as a *tested*
requirement; P4; and "pixel-perfect" as an acceptance gate rather than design evidence.

### Rejected

- **"Cut the monogram entirely."** A per-repo logo was an explicit product request and the sidebar
  group leans on it for scanability. Descoped instead: keep the glyph, drop the collision/grapheme
  over-specification and test fixed name→output fixtures rather than "two names differ".
- **"Drop the visual audit."** Kept as *evidence*, not as the acceptance criterion.

### Open decisions blocking rev 2

1. **Phasing.** The practice reviewer holds that a read-only P1 is ornamental and that the smallest
   shippable P1 is the worktree-root override end-to-end. The request was explicitly UI-first. These
   conflict; rev 2 needs one of them chosen.
2. **Write authorization** for non-script settings (above).


---

# Rev 2 — supersedes the rev 1 Decisions and Phasing tables

Both blocking decisions are answered, and the eleven confirmed errors are corrected. Where rev 1 and
rev 2 disagree, **rev 2 wins**; the rev 1 tables are kept only as the record of what was reviewed.

## The two answers

**Phasing — UI first, plus one editable row.** P1 ships the Settings section pixel-audited *and* makes
Worktree root editable end-to-end. This keeps the requested sequencing while removing the reviewer's
"ornamental" objection: the page can do exactly one real thing on day one, and that one thing is the
setting the feature exists for.

**Write authorization — host only, enforced at the transport.** And the mechanism already exists, which
is what makes this decidable rather than aspirational: `WsClient.isLocal` (`ws/client.ts:46`) is set
from the real socket address in `server.ts:733` (`127.0.0.1`, `::1`, `::ffff:127.0.0.1`), and it already
gates a privileged input — the app's reported pid in `hello` (SPEC-37 decision 6): *"a non-loopback
client must connect normally but may not ask us to sample an arbitrary pid."* Per-repo writes take the
same shape: **any paired device may read; only a loopback client may write.** This answers the
reviewer's objection that "host" needs an enforceable role rather than a UI assertion.

## Decisions (rev 2)

Rev 1's D1, D2, D4, D5, D7, D8 (as amended), D10, D12, D13, D14 (as amended) stand. Changed, added and
withdrawn below.

| # | Decision | Why |
| --- | --- | --- |
| **D3′** | The Git provider row is a **read-out with no override in any phase of this spec**. | Detection is authoritative and verified against four live forges. An override creates a second truth that would have to be threaded through routing, auth lookup *and* PR rendering — the reviewer's point, accepted. |
| **D6′** | Two badge families, not one vocabulary. **Provenance** (`detected`, `from remote`, `from name`) is a fact about where a value was read. **Resolution** (`inherited`, `from environment`, `overridden`) is a fact about configuration precedence, and only `overridden` carries a `SettingsResetButton`. | They are different things; forcing one "closed vocabulary" was uniformity for its own sake. |
| **D8′** | Resolution is **three levels**, not four: `repo override → env var → built-in default`. | There is no global settings store to inherit from. A four-level chain was a framework for a level that does not exist. |
| **D16** | **Only a loopback client may write per-repo settings.** A non-loopback client receives an explicit refusal, not a silent no-op. Reads are unrestricted. | `worktreeRoot` is a path the daemon creates directories under and, via prune, removes. A remote device that can set it directs host filesystem operations. Precedent: SPEC-37 D6 / `WsClient.isLocal`. |
| **D17** | Every path-valued setting is **canonicalised** before use and rejected if it is not absolute. Validation happens **server-side on write**, and again on read-back before use. **A worktree root that does not exist yet is normal and must be accepted:** canonicalise the nearest *existing* ancestor with `realpath`, then require the remaining segments to contain no `..` and no symlink. Reject only if the resolved ancestor itself escapes **the allowed area, which is `$HOME`** — the boundary `validateWorktreeRoot` enforces, chosen because prune *removes* directories under this root. **If no existing ancestor can be `realpath`ed, reject** (round-3 finding). Re-validate on read-back before use.<br><br>**What read-back validation does and does not close:** it defends against a `projects.json` edited by hand between write and use. It does **not** close the filesystem TOCTOU window — a local attacker who can write inside `$HOME` could replace a validated component with a symlink between the check and the `git worktree add`. That residual risk is accepted and recorded rather than mitigated: the attacker already needs write access to the user's home directory, where they could act directly. Race-resistant creation (`openat`/`O_NOFOLLOW` walks) is not available through the `git` CLI this code drives. | Validating only on write trusts a file the user can edit by hand — `projects.json` is plain JSON in `$MAKIT_HOME`. And `realpath` on a path that does not exist fails, so a naive rule would reject `~/work/worktrees` before the user has created it, which is the *common* case (round-2 finding). |
| **D18** | `RepoDTO.forge` is **genuinely pending-able**. Routing only happens when a gateway PR operation calls `pick`, so a repo with no eligible worktree may never be routed. Absent `forge` renders **no row**, and the row appears when detection lands — it is never guessed. | Rev 1 assumed every repo would be routed. Confirmed false. |
| **D19** | `repo_service` receives a **narrow `ForgeInspector`** — `forgeFor(repoPath)` plus `hasRemoteFor(repoPath)`, the name the plan and the code both use (an earlier draft of this table said `softwareFor`; there is no such method) — not the router. | `listRepos` takes `GithubGateway` (`repo_service.ts:62`) and `manager._gateway` is typed the same, so a router-only accessor is invisible across that boundary. Widening the gateway contract to carry inspection would put two responsibilities on one interface; a separate narrow port is the SOLID answer. |
| **D20** | `authed` means **"a credential is configured for this host"** — for Forgejo, `forgejoRefFromRemote(...).token !== undefined`; for GitHub, **omitted entirely**. | `gh`'s budget snapshot is not host-specific authentication. Reporting it as `authed` would be a guess dressed as a fact. |
| **D21** | The Settings taxonomy becomes a **function of the repo list**: `sectionsFor(repos)` — and the *search* path with it. `SettingsNavPane` calls `searchSettings(query)` and builds result titles from the static list, so both must take the dynamic sections or repo rows will be unsearchable and render as `repo:<id>` (round-2 finding). Section id is `repo:<projectId>` (the persisted id, not the path). If the selected repo disappears from the snapshot, selection falls back to `General`. Search entries are generated per repo section. | `kSettingsSections` is a static `final List` (`settings_registry.dart:24`) resolved statically by `settings_window.dart`. This is foundational, not incidental. |
| **D22** | Settings open state carries an **optional target section id**, replacing the bare `bool` (`window_overlays.dart:28`). | There is otherwise no way to open Settings *at* a repo. |
| **D23** | The P1 entry point is **desktop only**. `RepoCard` is the *mobile* home card (`home_screen.dart:53`); mobile Settings is a separate `/repos/settings` route. A mobile destination is out of scope for P1. | Rev 1's T4.1 targeted the wrong shell. Stating the scope is honest; pretending one task covers both is not. |
| **~~D11~~** | **Withdrawn as specified.** "Unknown keys preserved" is not free: `project-store.ts:81`/`:99` reconstruct and emit only `{id, path}`, and `manager.ts:204` copies only those into `ProjectDTO`. Rev 2 requires a *lossless round-trip for the `settings` object*, with an explicit test, in all three places — not an aspiration in a table. | |

## Cut from the spec entirely (accepted YAGNI)

The disabled Lifecycle Scripts group in P1 (advertises a dangerous feature before its trust model
exists); provider and default-branch overrides (D3′); the copy button; two-line rows as a blanket
mandate — subtitles only where they distinguish state; the monogram's hue determinism as a *tested*
requirement (keep the glyph, test fixed name→output fixtures); P4; and "pixel-perfect" as an
**acceptance gate** — the visual audit remains as *evidence*, alongside golden tests for geometry.

## Phasing (rev 2)

| Phase | Contents | Gate |
| --- | --- | --- |
| **P0 · foundations** | Router keeps a per-repo forge decision record; `ForgeInspector` port (D19); `sectionsFor(repos)` + `repo:<id>` ids + fallback (D21); Settings open-target (D22); lossless `settings` round-trip through store *and* manager (~~D11~~) | rev 2 reviewed |
| **P1 · the page, with one live control** | The section rendered from real data; Worktree root editable end-to-end — persisted, canonicalised (D17), loopback-gated (D16), and routed through `addWorktree`, `addWorktreeForPr` **and** `uniqueWorktreeDir`; desktop entry point (D23); widget + integration tests; visual audit; real-app run | P0 |
| **P2 · the rest of the rows** | Branch prefix; mobile destination; whatever the P1 page proves is missing | P1 shipped |
| **P3 · lifecycle scripts** | Unchanged, and still gated on D13(a)/(b) — plus the reviewer's additions: no script text sent to paired devices, config file ownership/permissions, interpreter, child-process-tree termination, output redaction, pre-prune veto timeout and override | D13 confirmed |

## What rev 2 explicitly does not do

No provider override, ever (D3′). No global settings store, so no four-level chain (D8′). No mobile
repo-settings destination in P1 (D23). No script execution (P3). No GitLab provider. No custom logo
image. No `All repositories…` overflow.


---

# Rev 3 — the four identity rows become editable

Requested after seeing the built section: **Logo, Root path, Git provider and Default branch must be
editable/selectable.** That reverses D4 and D14 as written, and re-opens two cuts that review round 1
made — so each reversal is justified by the *concrete failure case* the reviewer said was missing,
rather than by the request alone.

| # | Reversal | The failure case that justifies it |
| --- | --- | --- |
| **D3″** (was D3′, "read-out, no override, ever") | The provider is **selectable**: `Auto \| Forgejo \| Gitea \| GitHub`, `Auto` selected by default and its subtitle naming what it resolved to. | Round 1 cut this for having "no concrete failure case". There are two. Detection returns `unknown` for a private instance that answers 401 to an anonymous probe, and for an instance behind a proxy that hides `/api/forgejo/v1/version` — I verified both endpoints are the only discriminators. In either case the repo is routed to the *unsupported* provider and is unusable, **with no recourse anywhere in the product**. An override is the recourse. The reviewer's real objection stands and is accepted: it must control routing, auth lookup and PR rendering — not be a display preference. That is P2 work, and D3″ is not satisfied by the control alone. |
| **D4′** (was "displayed, not editable") | Root path is **changeable**. | "Remove and re-add" is not equivalent: it mints a new `PersistedProject.id`, and everything keyed to that id — per-repo settings, session history — is lost. A repo that simply **moved on disk** should keep its identity. Re-pointing preserves the id, which is the entire reason the id exists (`project-store.ts:28`). Constraint: it must re-validate that the target is a git repo and re-run detection, because the forge and default branch may both change. |
| **D14′** (monogram only) | The logo is **selectable** (colour + glyph from fixed sets). A custom *image* stays deferred. | Two repos whose names hash to the same hue are indistinguishable in the sidebar — which defeats the one thing the monogram exists for. Choosing from a palette needs no byte transfer, so it does not drag in the upload path that made a custom image P4. |
| **Default branch** (round 1: "no demonstrated consumer") | **Pickable from the repo's own branches.** | The consumer is concrete: `origin/HEAD` is genuinely absent after a `--single-branch` clone or a default-branch rename, and makit then shows the wrong base — so diff-vs-default and the PR base are both wrong. Picked from known branches, never free text: a typo silently breaks both. |

## What rev 3 does not change

D16 still governs: **only a loopback client may write any of these.** A non-loopback client sees the
same values, the selector inert, and one line saying where they are editable. Asserted by test.

And the controls are affordances only until P2 supplies persistence and, for the provider, the routing
change D3″ demands. A selector that reports a choice nothing acts on is exactly the "ornamental"
failure round 1 named; it is acceptable *only* because P1 was explicitly sequenced UI-first, and the
plan's P2 now owns four writes rather than one.

## Verification (rev 3)

Interaction is proven by **widget test, not on the real app** — a stated coverage gap. Driving the built
macOS app with `cua-driver` did not work: a sidebar row *and* a 107×28pt segmented-button segment both
returned `"effect":"unverifiable"` and left the UI unchanged, on two separate builds. The real-app pass
therefore covers appearance only. 15 widget tests cover behaviour, two proven to bite by reverting the
read-only gate and by making reset freeze the detected forge instead of asking for `Auto`.


## Rev 3.1 — the provenance badges and the copy button are cut

**D6″ supersedes D6′.** Rev 2 split badges into two families and kept both. Only the *resolution*
family survives, and only where nothing else in the row already says it:

| Row | Rev 2 | Rev 3.1 | Why |
| --- | --- | --- | --- |
| Logo | `from name` | — | The monogram **is** the value. A chip explaining it is a caption on a caption. |
| Root path | copy button | — (chevron) | Copying a path is not a configuration task — round 1 said so and was overruled at the time. The row is editable now, so the slot belongs to the chevron like its neighbours. |
| Git provider | `detected` / `overridden` | — | The subtitle already reads `Auto: GitHub · …` or `Set to Gitea · …`. The badge was the same sentence twice. The reset button stays: it is an action, not a label. |
| Default branch | `from remote` | — | `main` is the fact. Once the row is editable, where it came from stops being actionable. |
| Worktree root | `inherited` / `overridden` | **kept** | The only row with no subtitle, and the distinction is the whole point of the feature. |

The rule, stated once: **a badge appears only where nothing else in the row says it.** This is what
round 1 was reaching for — *"they are not one abstraction"* — and rev 2's compromise of keeping both
families kept the chrome round 1 objected to. Rev 3.1 finishes the cut.

Pinned by a negative test (`provenance badges are absent`) so they cannot creep back, and by one
asserting that with **two** things overridden there are two reset buttons but exactly **one** badge.


## Rev 3.2 — the provider can be None

`Auto | None | Forgejo | Gitea | GitHub`. **None** means makit talks to no forge for this repository and
stops checking pull requests.

It earns a segment because it answers two things nothing else could:

| Case | Before | After |
| --- | --- | --- |
| A purely local repo, no `origin` at all | `Auto: not identified yet` — implies a probe is pending when none can ever help. And the router sends it to the `gh` gateway, which fails on every poll. | `Auto: no remote, so no forge`, with a prohibit glyph. A conclusion, not a wait. |
| A mirror or vendored copy whose forge you do not care about | No way to stop the PR chatter | `None`, selected explicitly — an instruction, not an outcome |

The distinction is the point: **"we could not tell" and "there is nothing to tell" must not read the
same**, because only the first is worth investigating. Pinned by a test asserting the two subtitles are
different strings and that the pending one is absent when there is no remote.

This adds one fact to the DTO — `hasRemote` — which the server already computes (`git remote get-url
origin` runs in the routing path today) and currently throws away. And it makes P2's write set five:
worktree root, logo, root path, default branch, provider choice.


---

## P1 implemented — results

| Piece | Where | Proof |
| --- | --- | --- |
| Settings model, resolution, validation | `server/src/repo_settings.ts` | 21 tests |
| Lossless persistence, unknown keys included | `project-store.ts`, `manager.ts` | 3 round-trip tests |
| Per-repo worktree root, **all three consumers** | `manager.worktreeRootFor` → `addWorktree`, `addWorktreeForPr`, `uniqueWorktreeDir` | 5 tests, incl. a collision that only exists under the override |
| Host-only writes | `ws/commands/repo_settings.ts`, gated on `WsClient.isLocal` | 14 tests |
| Forge decision record + inspector port | `forge/router.ts` | 6 tests |
| Settings on the wire | `protocol.ts` `RepoSettingsDTO`, `repo_service.ts`, `manager.settingsDtoFor` | typed DTO |
| Wire → view mapping | `repoSettingsViewFor` | 11 tests |
| Dynamic sidebar sections | `sectionsFor(repos)`, `settings_window`, `settings_nav_pane` | 8 tests |
| The section itself | `repository_section.dart`, `repository_settings_page.dart` | 23 tests |

**Server 1429/1429, typecheck clean. `flutter analyze` clean.** Every group above had at
least one bite proven by reverting the production line: the loopback gate, the override lookup, the
collision-check root, the pinned filter, the nav-pane search threading, the read-only gate, and reset's
return to `Auto`.

### Two bugs the tests found that review did not

- **The `..` rejection was dead code.** It split a *normalised* copy of the path, and `normalize()`
  collapses `..`. The test could not catch it either, because `path.join` collapses too — the case only
  became reachable once the test built the string by concatenation. A traversal would have been rejected
  by the containment rule instead, with a misleading message.
- **`realpath` fails on a path that does not exist**, so canonicalisation had to walk to the nearest
  existing ancestor. Without that, naming a worktree root before creating it — the common case — would
  have been refused.

### What P1 does not do, and is honest about on screen

`Root path` shows a notice rather than an edit: re-pointing a project needs the daemon to re-check it is
a git repo and re-run detection, and getting that wrong silently detaches a project from its sessions.
The provider choice is **stored and served but does not yet re-route** — `D3″` demands it drive routing,
auth lookup and PR rendering, which is P2. Lifecycle scripts remain P3 behind `D13`.


### The live proof the tests could not give

A throwaway probe over the real machine — two real `git init` repos, a real
`projects.json`, a real `SessionManager`, and a real `git worktree add`:

```
settings survived the round trip                     PASS
an unknown key survived too                          PASS
the untouched repo stays two-key                     PASS
repo A uses its override    /Users/le/.makit-e2e-trees-alpha
repo B inherits             /Users/le/.worktrees
A reports source=override, B reports source=default  PASS
no token is ever on the wire                         PASS
A's unknown key was not clobbered by B's write        PASS
worktree created under the override
   /Users/le/.makit-e2e-trees-alpha/makit-alpha-DAfwAT/feat-e2e
...and not under the inherited root                  PASS
```

The last two are the point: the setting **moves where `git worktree add` writes**, which no unit test
can establish. The probe was deleted; its temp repos and roots were removed.

**Limitation it exposed:** the probe reloaded settings from the file rather than restarting the process.
Reload is what a restart does, but a true restart would also re-run detection, so the `forge` field's
behaviour across a restart is still unproven.


---

# P2 implemented — the settings stop being ornamental

P1 shipped five writes; **three of them changed no behaviour anywhere**, which is
precisely the failure round 1 named and rev 3 accepted as a risk. P2 closes that,
plus the one row that was missing entirely.

| Setting | After P1 | After P2 |
| --- | --- | --- |
| Worktree root | ✅ three consumers | unchanged |
| **Git provider** | stored, served, displayed — router ignored it | **routes**: picks the gateway, skips the probe, `None` reaches no forge |
| **Default branch** | stored, served, displayed — nothing read it | **resolved**: diff base, worktree base, wrap-up sync |
| **Logo hue** | stored, served, parsed — dropped in mapping | **drawn**, in the section and the sidebar |
| **Root path** | a notice: "not supported yet" | **re-pointable**, id and settings preserved |

## What the provider override does now (D3″ satisfied)

`forgejo`/`gitea` route to the REST gateway **without probing**, `github` to the
`gh` gateway (the only way to reach `gh` for a GitHub Enterprise host), and `none`
to a new gateway that reads no remote and makes no request.

Two decisions worth recording:

**The probe is skipped, not merely ignored.** The cases the override exists for are
exactly the ones where the probe cannot answer — a private instance that 401s an
anonymous request, one behind a proxy hiding `/api/forgejo/v1/version`. Spending it
anyway would delay every poll to learn nothing.

**`none` is not `unsupported`.** Unsupported means *we cannot talk to this forge*
and answers `unknown`; `None` means *do not talk to any forge here* and answers
`none`. `unknown` would make the app hold a stale PR pill and keep retrying
(SPEC-32 §6.5) — the exact chatter `None` exists to stop. Pinned by a test
asserting the two gateways do not report the same thing.

**The routing cache keys on the choice.** Without that the setting would apply only
after a daemon restart, which is indistinguishable from a broken feature. An
unchanged choice still shares one `git remote` read, so the fan-out stays cheap.

## Two bugs found while wiring it

- **`hasRemote` was derived from `forge !== undefined`.** Those two facts have three
  states between them — *not measured*, *no remote*, *a forge* — and one boolean
  cannot hold three. Every un-polled repo claimed to have no origin, which made the
  app's `Auto: not identified yet` branch **unreachable** and sent the reader
  hunting for a remote that was never missing. rev 3.2 pinned that these must read
  differently; the server could not produce the distinction. The router now records
  the remote as its own fact.
- **The re-point duplicate check compared paths at different canonicality.** On
  macOS `/tmp/x` and `/private/tmp/x` are one directory, so two projects could
  occupy one path — where settings and the forge decision, both keyed BY PATH, would
  answer for each other.

## Two tests that were vacuous until they were fixed

Recorded because both passed while proving nothing, which is worse than failing:

- a worktree-base test whose fixture branched from `main` with no commit of its own,
  so `merge-base` could not tell which branch was forked;
- a logo test asserting a chosen hue of `3` differed from the derived one — `Diana`
  hashes to 3.

## Verification

**Server 1496/1496, typecheck clean. `flutter analyze` clean.** Every group has a
bite proven by reverting one production line: the cache re-check, the override
branch, each new default-branch consumer, the loopback gate on `repo.path.set`, the
canonical duplicate check, and `sectionsFor`.

`app/integration_test/desktop/settings_repo_test.dart` (T6.2, the last undone P1
task) mounts the real `SettingsWindow` on a **real macOS build** and drives
`reposProvider → sectionsFor → nav pane → page → rows`. All five tests fail when
`sectionsFor` ignores the repo list.

### The live proof, over a real daemon

A throwaway probe — real git repos, a real `SessionManager`, the real command
router, a real `projects.json`, persistence wired exactly as `serve.ts` wires it —
**21/21**:

```
detection cannot identify the instance -> unsupported      PASS
the override RE-ROUTES with no restart          served=forgejo
and spends no probe -- the probe is what failed            PASS
repo B still routes on its own host              served=github
None reaches no provider at all                       served=
None answers 'none', not 'unknown'                        PASS
the snapshot's default branch follows the override   got=trunk
an un-routed repo reports hasRemote true                  PASS
a paired phone CANNOT re-point                            PASS
a non-git directory is refused with a reason              PASS
re-pointing onto another project's path is refused        PASS
the project KEEPS its id ...and its settings              PASS
the moved path survives the reload                        PASS
no token appears in the repos snapshot                    PASS
```

The first four are the point: the setting **changes which provider serves the
repo**, which no unit test can establish. The probe was deleted.

## "New worktree from PR" on both providers

Found by asking the obvious follow-up question: if the provider setting routes, does
the PR picker follow it? Listing did — `listOpenPrs` goes through the gateway. The
**checkout** did not: it ran `gh pr checkout` unconditionally, so the flow broke
exactly halfway. The user saw their Forgejo PRs, picked one, and the worktree never
appeared.

| Provider | List | Checkout |
| --- | --- | --- |
| GitHub | gateway → `gh` | `gh pr checkout` (unchanged) |
| Forgejo / Gitea | gateway → REST | **`refs/pull/<n>/head`**, plain git |

`gh` is kept for GitHub rather than replaced by the generic path: it already handles
fork PRs and sets up push tracking, and swapping a working path for a hand-rolled
equivalent is a regression risk taken for tidiness. `refs/pull/<n>/head` is used for
Forgejo instead of the head branch name because the forge creates it for **every** PR
including forks', whose branch is not on `origin` at all.

Upstream tracking is set only for a same-repo PR, so a push updates the PR. For a
fork it is left unset on purpose: pointing it anywhere would aim a push at a branch
that is not the PR's.

The strategy resolves from the same two sources, in the same order, that the router
uses to pick a gateway — override first, then detection — so the checkout cannot
disagree with the provider that served the list.

Proven end to end over the real commands (`pr.list`, `worktree.createFromPr`) against
a real bare repo publishing a real `refs/pull/7/head`, **12/12**: listed by the
Forgejo provider on a host detection could not identify, strategy `pull-ref`, worktree
at the PR's commit under the repo's own worktree root. The GitHub path, which had no
test at all before this, is now pinned argv-and-all through a PATH shim.

## What P2 does not do

- **Lifecycle scripts** remain P3, still gated on D13(a)/(b).
- **Branch prefix** has no source and is still not rendered (D9).
- **A repo-card entry point on mobile** — repo sections are reachable from the
  desktop sidebar; the mobile destination and the `repo:<id>` deep link (F5/T5) are
  not built. Nothing is unreachable as a result.
- **Sessions already bound to a worktree keep their recorded paths** across a
  re-point. For the case D4′ exists for, worktrees live under the worktree root and
  are unaffected; a session whose worktree was the repo directory itself still
  points at the old location. Stated in the code, not only here.
- **Interaction on the real app is still verified by test, not by clicking.**
  `cua-driver`'s synthesized clicks do not land in this Flutter app
  (`"effect":"unverifiable"` on three builds), so the macOS integration test is the
  substitute — it is a real build, driven by the Flutter harness rather than by the
  window server.
