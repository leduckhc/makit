# SPEC-48 — Per-repo settings: one Settings section per repository

**Status:** Draft (rev 2.1) — review rounds 1 and 2 applied · **Priority:** P2 · **Branch:** `feat/forgejo-git-provider`
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
| **D17** | Every path-valued setting is **canonicalised** before use and rejected if it is not absolute. Validation happens **server-side on write**, and again on read-back before use. **A worktree root that does not exist yet is normal and must be accepted:** canonicalise the nearest *existing* ancestor with `realpath`, then require the remaining segments to contain no `..` and no symlink. Reject only if the resolved ancestor itself escapes the allowed area. | Validating only on write trusts a file the user can edit by hand — `projects.json` is plain JSON in `$MAKIT_HOME`. And `realpath` on a path that does not exist fails, so a naive rule would reject `~/work/worktrees` before the user has created it, which is the *common* case (round-2 finding). |
| **D18** | `RepoDTO.forge` is **genuinely pending-able**. Routing only happens when a gateway PR operation calls `pick`, so a repo with no eligible worktree may never be routed. Absent `forge` renders **no row**, and the row appears when detection lands — it is never guessed. | Rev 1 assumed every repo would be routed. Confirmed false. |
| **D19** | `repo_service` receives a **narrow `ForgeInspector`** (`softwareFor(repoPath)`), not the router. | `listRepos` takes `GithubGateway` (`repo_service.ts:62`) and `manager._gateway` is typed the same, so a router-only accessor is invisible across that boundary. Widening the gateway contract to carry inspection would put two responsibilities on one interface; a separate narrow port is the SOLID answer. |
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
