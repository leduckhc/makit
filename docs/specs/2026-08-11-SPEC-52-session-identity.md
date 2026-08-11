# SPEC-52 — Session identity: copy the id, and its transcript

**Status:** Implemented — P1 (rev 2 — dual review applied) · **Priority:** P2 · **Branch:**
`feat/get-session-id`
Deferred to P2: the codex/`threadId` resolver branch, and D12's identity section inside the
context-usage panel (cut on review — see the plan's deviations 4 and 5).

> **Renumbered 51 → 52.** This spec was drafted as SPEC-51, and while it was in flight two other specs
> took the numbers around it on `main`: *Preview groups* took 51
> (`2026-08-12-SPEC-51-preview-groups.md`, #163, referenced from `docs/UX.md` and fourteen shipped
> source files) and *Profiles* took 50 (`2026-08-10-SPEC-50-profiles.md`, #162). Both shipped first and
> neither can move, so this one took 52, the next free number. The branch name
> (`feat/get-session-id`) is deliberately left alone — renaming a pushed branch would orphan its PR for
> no gain.
>
> The rename does not fix the underlying hazard: nothing in the repo allocates spec numbers, so two
> branches drafted in the same week collide silently. `main` already carries the proof — SPEC-48 names
> *both* `2026-08-09-SPEC-48-status-and-activity.md` and `2026-08-10-SPEC-48-per-repo-settings.md`.

**Depends on:** SPEC-29 (`agentSessionId` / `resumeSessionPath` persistence, closed-session
resume), SPEC-37 (`ContextUsageDetails` — the panel this appends to, and the ring's absence
rule this must not weaken), SPEC-47 D12 (the precedent for adding one optional field to
`SessionDTO` rather than a new command), SPEC-35 (the mid-turn queue — the thing that makes
the current workaround useless).
**Design board:** [`mockups/session-identity.html`](../../mockups/session-identity.html) —
one panel, three doors, one **Copy all**. Rejected variants recorded there in §"Rejected
alternatives"; the four per-row copy buttons were designed, then superseded, and that row is
kept so review does not re-propose them.

---

## Goal

Get the underlying agent session id — and the path to its transcript — onto the clipboard
**while the agent is mid-turn**, because that is exactly when you need it: you are handing this
session's work to a second session and you cannot wait for the turn to finish.

| Question | Answered by |
| --- | --- |
| "what is this session's id, right now, mid-turn?" | `/session id` (client command) or the tab menu's **Copy session id** — bare id, zero dialogs |
| "give me everything I need to hand this off" | **Session details** → one panel → **Copy all** (D5) |
| "where is the transcript on disk?" | the `transcriptPath` row, server-resolved (D2/D3) |
| "how do I resume it in a terminal?" | the `Resume with` row (D10/D15) |

## The problem, precisely

`/session` is pi's own slash command. Typed into makit's composer it is **not** intercepted —
`clientCommands` (`app/lib/ui/composer/client_commands.dart:69`) holds only `new, cancel,
unpair, help, ask, compact, thinking, model, name` — so `handleClientCommand` returns false and
the send path falls through to `store.sendMessage` (`desktop_chat_pane.dart:183`). Mid-turn the
server cannot steer it into the running turn, so it lands in `Session.queued`
(`server/src/session.ts`, cap `MAX_QUEUED_MESSAGES = 50`) and executes on the next idle
transition — after the handoff you wanted has already gone stale.

There is no other route. The app has never been told the id at all.

## What already exists (and is thrown away)

This is not new telemetry. Both values are already computed, already persisted, and already
survive a restart:

- **`Session.agentSessionId`** (`server/src/session.ts:163`) — the native ACP `sessionId` (set
  at `acp.ts:285`) or codex `threadId` (`codex.ts:200`). Persisted via `toMeta()`
  (`session.ts:305`, the field at `:317`) → `storage/sqlite_event_store.ts:142`, restored on rehydration, and used as the
  resume handle by SPEC-29.
- **`Session.resumeSessionPath`** (`session.ts:155`) — the on-disk transcript for sessions
  attached from disk (`manager.ts:1176`, from `listPiSessions`).
- **`piSessionsDir(cwd)`** (`server/src/pi-sessions.ts:52`) — pi's slug algorithm, already
  implemented and unit-tested (`pi-sessions.test.ts`), already used to list and parse prior
  transcripts.

They are simply **absent from `SessionDTO`** (`protocol.ts:689`). The whole feature is one
projection plus a panel.

**And the id is the right one.** `pi-acp` reuses pi's *own* session uuid as the ACP
`sessionId` — verified against `~/.pi/pi-acp/session-map.json`, whose entries map
`sessionId → {cwd, sessionFile}` with the same uuid inside the filename. So `agentSessionId`
for a pi session is exactly the value pi's `/session` prints and `pi --session` accepts.

## Why the context-usage ring cannot be the home for this

`ContextUsageButton` opens with
`if (usage == null || fraction == null) return const SizedBox.shrink();`
(`app/lib/ui/composer/context_usage.dart:218`). The ring is therefore **absent** in four
states, one of which is the single likeliest moment of need:

1. before turn 1 — *you are seeding a second session from a fresh one*;
2. on pi without the `makit-pi-usage` extension installed;
3. after a pi compaction, until the next reply (pi nulls the count);
4. whenever an agent reports cost or tokens but no window.

A control that vanishes in four states cannot be the only route to a value needed in all of
them. **The absence rule is not weakened** (D12) — the panel is reachable without it, and is
*additionally* appended inside it when it happens to be there.

## Decisions (locked)

| # | Decision | Why / consequence |
| --- | --- | --- |
| **D1** | Two **optional** fields on `SessionDTO`: `agentSessionId?: string`, `transcriptPath?: string`. No new `cmd` kind. | Rides the existing session snapshot, so the values arrive *with* the session and cost zero round-trips mid-turn. Optional on the wire so a new app against an old server renders fewer rows, never a fabricated one — the `createdAt` precedent (SPEC-47 D12). |
| **D2** | `transcriptPath` is resolved **server-side only**. The app never derives it. | The slug algorithm is pi's, lives in `pi-sessions.ts`, and is already tested there. Duplicating it in Dart would be a second source of truth that drifts on the next pi change — and the app cannot stat the server's filesystem to check itself. |
| **D3** | Resolution happens **in `SessionManager`**, not in `Session.toDTO`, with `cwd = session.worktreePath ?? project.dto.path`. Order: (a) `resumeSessionPath` verbatim; (b) else, for pi only, the entry in `piSessionsDir(cwd)` whose basename ends `_<agentSessionId>.jsonl`; (c) else **absent**. Memoized per session id — **including misses** — so it costs at most one `readdir` per session per server lifetime and **zero I/O per snapshot**. | Three corrections, all found in review. (i) **`Session` does not know its project's filesystem path** — it holds `projectId` and `worktreePath` only (`session.ts:146,514`), so `toDTO` *cannot* resolve this; the manager can, via `this.projects.get(...)`. (ii) **pi's slug is derived from the cwd pi actually ran in, and that is usually the worktree** — `manager.ts:923` spawns with `worktreePath`, `:1358` with `project.dto.path`, `:1505` with a computed cwd. Verified on disk: this session's transcript is under `--Users-le-.worktrees-makit-feat-get-session-id--`, *not* a project-root slug. Copying the nearest precedent (`attachPiSession`, `manager.ts:1176`, which uses `project.dto.path`) would have silently missed the transcript for **every worktree-bound session** — i.e. every session this feature exists for — and D9 would have hidden the failure. (iii) The reattach path already documents this exact rule (`manager.ts:1478-1485`) but confirms membership with an **async** `listWorktrees`; that is unaffordable per snapshot, and unnecessary here — a wrong directory simply yields no match, and D9 hides the row. |
| **D4** | Paths are **absolute everywhere** — wire, clipboard *and* display. No `~/` abbreviation, no middle-elision. The row wraps. | The receiver of a copied path is another agent's shell or prompt, and `~` only expands if a shell gets there first. The mockup abbreviated to `~/.pi/agent/…`; **that was caught in planning as unimplementable**: the path belongs to the *server host*, and the app cannot know that host's home directory. Faking it needs either a `/Users/<x>/` heuristic (wrong on a Linux host, wrong for a non-standard home) or shipping `homeDir` on the wire for pure cosmetics. Absolute-and-wrapped is truthful, and it is what gets copied regardless. |
| **D5** | **One** copy affordance in the panel: a `Copy all` action row. No per-row copy buttons. | Four 24 pt targets stacked 30 pt apart on a phone, a toast that cannot say which one was hit, and 116 px stolen from every value — enough to wrap a 36-char uuid mid-string, which invites a partial selection. Measured in the mockup: dropping the copy column took both uuid rows from 2 lines to 1. |
| **D6** | Single-value copy is not lost, it **moves**: `/session id` and the tab menu's **Copy session id** each copy the bare `agentSessionId` and nothing else. | The panel answers "give me the context"; those two answer "give me the id". One surface is not asked to be both. This is what makes D5 affordable. |
| **D7** | `/session` is a **client** command in `clientCommands`, never sent to the agent. | The only mechanism that works mid-turn: `handleClientCommand` is checked *before* `sendMessage` (`desktop_chat_pane.dart:170`, `session_screen.dart:671`). Bare → opens the panel; `id` → copies the bare id. |
| **D8** | The panel is **read-only**. No rename, no regenerate, no delete, no resume button. | Lifecycle already lives in the same menus (Close / Quit agent) and must not sit one mis-tap from the copy row. |
| **D9** | A row whose value is unmeasured is **omitted**, never rendered blank or as a placeholder. `Copy all` then copies fewer lines. | Same rule SPEC-37 settled on for the ring. A fabricated path is worse than no path: it will be pasted into a prompt and the next agent will report it missing. |
| **D10** | Per-agent vocabulary is a **lookup table** keyed by `SessionDTO.agent` (not a `switch`): pi → label `pi session`, resume `pi --session <id>`; codex → label `Thread`, resume `codex resume <id>`; anything else → label `Agent session`, **no** resume row. | Codex's own word for it is a thread (`thread/start` → `thread.id`). An unknown ACP agent gets no resume line because we do not know its CLI — inventing one is D9's failure mode in command form. A table rather than a `switch` because `docs/ENGINEERING.md`'s OCP rule is explicit: adding an adapter must not mean editing a growing `switch`. The safe default *is* the open/closed escape hatch — a third agent works unedited, just without a resume line. |
| **D11** | One host-agnostic body (`SessionIdentityDetails`) presented as a modal bottom sheet on mobile and a `MenuAnchor` popover on desktop. | Verbatim the `ContextUsageButton` / `ContextUsageDetails` split (`context_usage.dart:199-300`), including the window-clamped width and the `SingleChildScrollView`. |
| **D12** | **CUT from P1 → P2.** No `SessionIdentitySection` inside `ContextUsageDetails`. The ring's absence rule (`context_usage.dart:218`) is untouched, as before. | Cut on review, and the argument is this spec's own: the ring is absent in the four states above, *including the likeliest moment of need*, so a door hung off it is missing exactly when it is wanted — near-zero marginal value on top of the two menu doors and `/session`. It is not free either: it adds a `session_identity → context_usage` import edge, and it would put stacked mono rows beside `_Row`'s label/value rows in one panel. Deferring also deletes a whole task whose test was checking the wrong invariant (see §Review findings). |
| **D13** | **Two** panel doors, in menus that already exist and are always present: mobile `_glassMenu` (`session_screen.dart:505`) and the desktop pane-header kebab (`pane_header.dart:154`). The desktop **tab** menu gets **Copy session id** only. | Cut from three on review: a tab-menu *Session details…* is redundant with a pane-header kebab one pixel away on the same platform. The tab menu keeps **Copy session id** because that is a different job (right-click → one click → done), not a second way to open the same sheet. Zero permanent chrome either way; SPEC-40's 375 pt crowding is untouched. |
| **D14** | The clipboard payload is produced by one **pure** function, `sessionIdentityText()`, shared verbatim by the panel, `/session` and both menus. Format: one `label: value` per line, labels padded to a common width, absolute paths, omitted rows absent. | Pure ⇒ unit-tested directly, the same seam `formatTokens` / `headroomLabel` use. One function ⇒ the copy contract cannot diverge between four call sites. Plain lines survive being pasted into a prompt, a commit message, an issue or a terminal comment; markdown or JSON would need escaping. |
| **D15** | The resume command carries the **full** id, never a shortened prefix. | pi documents `--session <path\|id>` as accepting a "partial UUID", and the mockup used `pi --session 019ff121`. **That is unsafe and was caught before implementation:** pi session ids are UUIDv7, whose first 48 bits are a millisecond timestamp, so an 8-char prefix pins only the top 32 bits and leaves ~65 s of ambiguity. Real collisions exist on this machine — `~/.pi/agent/sessions/--Users-le-.worktrees-makit-when-we-migrated-to-pi-acp-server--/` holds `019fa9f4-443d-…` **and** `019fa9f4-d3c8-…`, and another directory has four files sharing `019f8471`. A copy button that emits an ambiguous resume command is worse than no button. |
| **D16** | `transcriptPath` for **codex** is P2, not P1. P1 ships codex's `Thread` id and resume command with no path row. | The rollout lives at `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<threadId>.jsonl` — a date-sharded walk with no existing helper, unlike pi's one-directory lookup. D9 lets P1 simply omit the row, so nothing is fabricated and nothing needs redesigning later. |
| **D17** | No new event kind, no broadcast, no watch. | Identity is session *meta*, not a session event. It changes at most once per session (when the adapter starts and `session.ts:388` assigns it), and `metaChanged` already fans out a fresh snapshot. |
| **D18** | **Accessibility is a locked decision, not a follow-up.** The `Copy all` row carries an explicit semantics label naming what it copies and how much (`Copy session details, 4 lines`). Each value row is a `Semantics` node whose label is the human label plus the value; the raw uuid is **not** re-spelled character by character. Covered by a widget test, because the row-QA harness cannot drive hover or VoiceOver. | SPEC-47 D17 already locked a11y for this exact surface family; this spec had nothing, which review correctly called a house regression. A copy-only panel is the worst place to omit it: a screen-reader user cannot see that a tap succeeded, so the label must say what the affordance does *before* the toast confirms it. |
| **D19** | The panel **watches** `sessionIdentityProvider` and rebuilds; it does not capture a snapshot at open time. | A draft's panel can be opened *before* the adapter assigns `agentSessionId`. That assignment fans out a fresh snapshot (D17), so a watching panel fills in its rows live, and a snapshotting one lies until reopened. One `ref.watch` instead of one `ref.read`, plus a test that drives the id in while the panel is open. |
| **D20** | Labels are hard-coded English, singular-only (`pi session`, `Transcript`, `Resume with`, `Copy all`). | Mirrors SPEC-47 D20 verbatim. Called out so review does not re-open it. |
| **D21** | `transcriptPath` discloses the **server host's** absolute filesystem layout — including its username — to any paired device. Accepted, and written down here. | Consistent with what the wire already carries (`worktreePath`, `cwd`, port paths) under the LAN/tailnet pairing trust model: a paired device is already trusted with the repo's contents. `docs/ENGINEERING.md` requires the disclosure be stated rather than assumed, and it is the reason the path is **read-only** on the wire (D8) — the app never sends a path back for the server to open. |

## What P1 does not do

- **No codex transcript path** (D16). The row is absent for codex; the id and resume line are not.
- **No Share transcript.** Getting the file from the server host to the phone is the media /
  file-serving path, not a clipboard. It is drawn in the mockup marked `follow-up` and is P3.
- **No `⌘I` shortcut.** Proposed in the mockup, deliberately unclaimed until `lib/shortcuts/`
  is audited for a conflict. P4.
- **No transcript *viewer*.** Copying a path is the feature; rendering a foreign transcript is
  a different one.
- **No right-click menu on the chat body.** There is no `onSecondaryTap` on the transcript
  anywhere in `app/lib/` today (the only two are `split_view.dart:641` and
  `groups/group_bar.dart:133`). Claiming secondary-click over the transcript would fight text
  selection and `chat_message.dart`'s per-message copy for a value that is not per-message.
- **No identity section inside the context-usage panel** (D12, cut to P2). The ring's absence rule is
  untouched and no new control enters the composer footer.
- **No third panel door** on the desktop tab menu (D13) — that menu gets **Copy session id** only.

## What P1 reuses

| Reused | From | Instead of |
| --- | --- | --- |
| `piSessionsDir()` + slug algorithm | `server/src/pi-sessions.ts:52` | re-deriving pi's layout |
| `agentSessionId` persistence + rehydration | SPEC-29, `storage/sqlite_event_store.ts:142` | a new table or a live-only field |
| optional-field-on-`SessionDTO` pattern | SPEC-47 D12 (`createdAt`) | a new `cmd` kind |
| host-agnostic body + sheet/popover split | `context_usage.dart:199-300` | two divergent panels |
| `themedMenuItem` | `app/lib/ui/widgets/` (used by all three menus) | bespoke menu rows |
| `Clipboard.setData` + `status.info('… copied', detail:)` | `port_detail_sheet.dart:224-229` (the only site passing `detail:`) | a new toast surface |
| pure-formatter-with-unit-tests seam | `context_usage.dart` (`formatTokens`, `headroomLabel`) | logic inside a widget |
| `ClientCommand` record + `handleClientCommand` interception | `client_commands.dart:26-66` | a new send-path branch |

## Phases

| Phase | Contents |
| --- | --- |
| **P1** (this spec) | D1–D15, D17: wire fields, pi path resolution, `sessionIdentityText()`, the panel, three menu doors, `/session`, the usage-panel section |
| **P2** | codex rollout-path resolver (D16) |
| **P3** | Share transcript (file transport to the device) |
| **P4** | `⌘I` after a `lib/shortcuts/` audit |

## Review findings applied (rev 2)

Two independent reviews ran against rev 1 before any code was written: one for technical
correctness (told to verify every citation and *run* every command against the real binaries),
one for engineering practice (TDD/SOLID/YAGNI/house style, with a mandatory `CUT THIS` list).

**Measured baselines, to be preserved:** `tsc -p . --noEmit` clean · `pnpm test` **1313 pass / 0
fail** · `flutter analyze --fatal-infos --no-pub` "No issues found".

| Finding | Disposition |
| --- | --- |
| **D3 was unbuildable as written** — `Session` has no project path, and pi's slug follows the *worktree* cwd, so the cited precedent would have missed every worktree-bound session. | **Accepted, and fixed beyond the proposal.** Resolution moved to `SessionManager`; cwd = `worktreePath ?? project.dto.path`; memoized including misses, because the reviewer's "resolve at projection time" would have done a `readdir` per session per broadcast. |
| `resolveTranscriptPath` should not live in `pi-sessions.ts` — steps (a) and (c) are agent-agnostic, so P2/codex would force a move. | **Accepted.** New `server/src/transcript-path.ts` owns the dispatcher and delegates to `pi-sessions.ts`; P2 becomes additive. |
| D10's per-agent `switch` violates the house OCP rule. | **Accepted.** Lookup table with a safe default (D10). |
| D12 (identity inside the usage panel) is missing exactly when it is needed, and adds coupling. | **Accepted — cut to P2** (D12). |
| Three panel doors is one too many; the tab-menu *Session details…* duplicates the pane kebab. | **Accepted — two doors** (D13); the tab keeps *Copy session id*. |
| No accessibility decision at all, where SPEC-47 locked one. | **Accepted — D18**, with a widget test. |
| A panel opened before the id is assigned would show stale rows. | **Accepted — D19** (watch, don't snapshot). |
| `transcriptPath` leaks the server's FS layout; state it. | **Accepted — D21.** |
| i18n divergence from SPEC-47 D20. | **Accepted — D20.** |
| Unproven or misdirected tests: `transcriptPath` never asserted in the projection; provider task had no test at all; the usage-panel test could not fail; label-padding and `/session`-branch mutations missing. | **Accepted** — all folded into the plan's rev-2 task list. |
| D15's collision risk is real — and worse than stated: `pi --session 019fa9f4` does **not** error on ambiguity, it silently resolves to one session and offers to fork it. | **Accepted as reinforcement.** D15 stands; the silent-wrong-session behaviour is now the stated reason. |
| Consider cutting the `resume` row entirely — it is the sole reason D10 and D15 exist. | **Rejected.** It is the highest-value line for the stated goal (handing work to a second session), and D15's cost is already paid. Cutting it would leave the user to reconstruct a command from an id, which is the manual step this feature exists to remove. |
| Persist `transcriptPath` so cold sessions report it without re-resolving. *(considered, not raised)* | **Rejected.** Needs a schema migration for a value that the memoized lookup recomputes in one `readdir` on the session's first projection after a restart. |
| D17, D12 self-consistency, D1's wire optionality, and the `pi-acp`-reuses-pi's-uuid claim all verified correct under attack. | No change. |

## Verification

Required evidence, not claims. Recorded as measured:

1. `cd server && node_modules/.bin/tsc -p . --noEmit` clean; `pnpm test` **1326 pass / 0 fail**
   (baseline 1313 — +13 net new, nothing regressed). ✅
2. `cd app && flutter analyze --fatal-infos --no-pub` → "No issues found!";
   `flutter test --no-pub` → **0 non-`loading` failures**. The 15–17 reported failures are all of
   the form `loading <file>`, and the set varies run to run; each one passes when run directly.
   That is the recorded flake baseline (harness load timeout under full-suite concurrency), not a
   regression. The 71 SPEC-52 tests are green run as a set. ✅
3. Every new test's bite proven by reverting **only** the production line — 9 mutations across the
   two trees, listed in the P1c commit body. The two load-bearing ones: `cwd` → project path fails
   the worktree test, and relaxing the transcript suffix match to a prefix fails the D15 collision
   test. A tenth — `handleClientCommand`'s exact name match → `startsWith` — is caught by
   `test/session_command_test.dart`'s "`/sessions` is NOT intercepted". ✅
4. **Pixel sign-off on the real macOS app**, not on a widget test: the panel rendered through
   `app/tool/session_identity_demo.dart`, geometry read from the accessibility tree via
   `cua-driver get_window_state` (AX space = Flutter logical px), row pitch and both uuid rows
   measured at **one line**, compared against `mockups/session-identity.html`. Light-mode
   `Copy all` measured 10.95:1 contrast (needs 4.5); line counts 4/3/3/2/1 all correct. That gate
   — not any test — is what found the "1 lines" pluralisation bug, now asserted in both the
   visible and the semantics label. ✅
5. **Live probe** (throwaway, deleted): `resolveTranscriptPath` run against the real
   `~/.pi/agent/sessions` tree, for this branch's own worktree, with the pi session id of the
   session that implemented the feature. It returned
   `…/--Users-le-.worktrees-makit-feat-get-session-id--/2026-08-11T14-01-46-945Z_019ff121-….jsonl`
   — byte-identical to the path pi itself reports for that session. The same call with the 8-char
   prefix `019ff121` returned `undefined`, so D15 holds on real data. Non-pi, draft, and
   unreadable-dir inputs all returned `undefined` without throwing (boundary rule). `pi --help`
   confirms the resume line's spelling, `--session <path|id>`, which accepts both the full id and
   the transcript path the panel offers. ✅
