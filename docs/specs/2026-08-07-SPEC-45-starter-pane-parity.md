# SPEC-45 — The starter pane keeps its work: draft text, slash commands, attachments

**Status:** Draft · **Priority:** P2 · **Branch:** `feat/new-session-remembers-input-text`
**Depends on:** SPEC-27 (in-pane starter, cached capability catalog, apply-at-launch picks),
SPEC-28/SPEC-30 (tabs and groups — the tab switch that loses the draft), SPEC-33 (user
attachments: `POST /media`, `composerAttachmentsProvider`, `send.message attachments[]`),
SPEC-31 (per-agent recents in `shared_preferences` — the persistence pattern reused here).

---

## Goal

"Choose a harness" (`WorktreeStarter`) is where a session begins, but it is not the composer the
live pane is. Three capabilities the live pane has, it silently lacks — and each one loses user
work or blocks a normal gesture:

1. **The typed message is destroyed by a tab switch.** `split_view.dart` keys `DesktopChatPane` by
   tab id (*"switching tabs recreates the pane state (composer draft is re-seeded)"*), so the
   starter's local `TextEditingController` is disposed with it — and so are the harness card it
   selected and the model / reasoning picks made for it. The live pane survives because it seeds and
   persists through `composerDraftsProvider`; the starter never touched it.
2. **The slash palette has no agent commands** — no skills, no prompts, no extensions. The starter
   never passes `Composer.commands`, so only the built-in client commands (`/cancel`, `/new`,
   `/model`) appear.
3. **The paperclip is inert.** `composerAttachments()` requires an existing session, so an image
   cannot be attached to the message that *starts* the session.

The unit of work is the pane's draft: everything typed, picked or pasted before the session exists
is real user work and must survive the pane's widget being recreated.

## Why the draft store already anticipated this

`composer_draft.dart` documents its own key space as *"the session id for an active session, **or a
worktree-scoped key for a session that hasn't started yet**"*, and is deliberately not
`autoDispose` so *"a half-typed message survives the composer's widget being disposed and
recreated"*. That second key was designed and never wired. This spec wires it; it does not
introduce a second draft mechanism.

## Why the slash commands cannot come from the existing capability cache

`capability_cache.ts` already serves the starter's model/reasoning pills with no live session:
`agentId → { fingerprint, configOptions }` at `~/.makit/capability-cache.json`, filled lazily on
the first `agents.list` by a throwaway `session/new` in a temp dir. Commands look like one more
field on it, and are not, for two reasons:

- **They are not in the response.** `NewSessionResponse` carries `sessionId`, `modes` and
  `configOptions` only; commands arrive afterwards as a `session/update`
  (`available_commands_update`, mapped at `adapters/acp-map.ts`). The probe would have to stay
  connected and *listen* rather than read a return value.
- **They are cwd-dependent; models are not.** A model catalog is the same in every directory. A
  command list is not: a temp-dir probe sees global skills and extensions but none of the
  repo's own (`.agents/skills/`, `.pi/`). The cache key would have to become
  `agentId + fingerprint + cwd`.

Neither is a blocker, but both are a probe redesign. So the palette is populated here from what a
live session **already told the app**, and the probe is phased (see Phasing).

## Decisions (locked before implementation)

| # | Decision | Why |
| --- | --- | --- |
| **D1** | **The starter's draft key is `starter:<projectId>\u0000<worktreePath>` (built by `starterDraftKey`), in the existing `composerDraftsProvider`.** Same `initialText` / `onDraftChanged` wiring as the live pane, plus a restore on a refused spawn (the composer clears its field on send, so without it a send that never happened still cost the message). | The store was built for exactly this key (quoted above), is already app-wide and already pruned on clear. A second mechanism for "the same half-typed message, before it has a session" is the divergence SPEC-33 §4.1 warns about. Keyed by **path**, not tab id: the same worktree opened in two tabs is the same intent, and the draft then also survives the tab being closed and reopened. The restore is what makes the pane coherent with D6 — keeping the images of a failed send but dropping its text would be a strange half-promise. |
| **D2** | **The harness pick and the config picks are persisted too, in their own `starterPicksProvider`** keyed by the same starter key. Choosing a harness still drops the previous one's picks; a started session clears the entry, a refused spawn keeps it. A stored harness is **re-validated against the catalog** on every build — honoured while still offered and available, dropped once it is not (an *empty* catalog means "not loaded yet", so the pick stands). | Same bug class as D1 and the same lifetime, so leaving it out would have fixed "my message vanished" while leaving "my harness reset to pi" — the pane's other half of the same gesture. A separate store rather than a widened draft store because the shape differs (`Map<String, String>` vs a record); they are keyed identically and pruned at the same moment. Clearing on a successful spawn is what keeps this a *draft* store and not an unrequested sticky-harness preference: the picks describe the session being composed, and that session now exists. Re-validation is new work the pick's new lifetime creates: before, an unavailable harness could not be "remembered" across a restart into a spawn the host cannot start. |
| **D3** | **Cached commands are client-side, keyed `agentId + projectId`, persisted in `shared_preferences`.** Loaded by the desktop and mobile bootstraps, ephemeral by default (tests). | Mirrors `RecentModelsController` exactly — single JSON key, corrupt-tolerant, non-persisting default. No protocol change, no probe, no spawn. Keyed by **project**, not worktree: sibling worktrees of a repo carry the same `.agents/skills`, so per-worktree keys would multiply misses for no gain in accuracy. |
| **D4** | **Only what a live session advertised is ever cached.** The cache is written when a pane observes `session.commands` for a session, under that session's `(agent, projectId)`. Nothing is synthesised, and the built-in client commands are not stored (the palette adds those itself). | A palette that invents commands is worse than an empty one: `/skill:x` that the agent does not have is a wasted turn. Recording an observation keeps the cache's contents exactly as true as the session that produced them. |
| **D5** | **Staleness is accepted and unmarked.** A cached command the agent has since removed is offered, sent, and refused by the agent. The cache is capped at `kCachedCommandKeysMax` `(agent, project)` entries, oldest-written evicted. | The alternative is a "possibly stale" badge on every row of the pre-session palette, which is noise on the common case (a skill list changes far less often than a session starts). The cap is what keeps a long-lived install's prefs blob bounded — pi advertises ~100 commands per project. |
| **D6** | **The starter is attachment-capable, staged under the same starter key, and the images ride the spawn.** `takeAttachmentsForSend` runs **after** the spawn succeeds, so a failed spawn leaves the chips staged rather than eating them. | `POST /media` is content-addressed and session-independent, `composerAttachmentsProvider` is already keyed by an opaque `String`, and `send.message`/`appendOptimisticMessage` already take `attachments`. The only thing that blocked this was `composerAttachments()`'s "a session must exist" guard, which is about *where to upload*, not *what to key by*. Ordering is safe: the server materialises attachments at send time, into the cwd the spawn already resolved. |
| **D7** | **The paperclip's precondition is a reachable server only** — `mediaUploaderProvider != null`. Not a session, not a recorded worktree. | The live-pane guard's session check has no meaning before a session exists; keeping it would have made the paperclip permanently inert here. The upload target is the same route with the same bearer either way. |
| **D8** | **The starter's palette offers agent commands only** — no client commands (`/model`, `/cancel`, `/compact`, …), via a new `Composer.clientCommands` flag. | Not cosmetic: `handleClientCommand` takes a **required `sessionId`**, and the starter's send path (`_start`) does not route through it at all, so picking `/model` here spawned a session whose first message was the literal text `/model`. SPEC-38 already made this call for the queue editor (*"client commands run NOW, and this message runs later"*); the starter's case is stronger — there is nothing for them to act on. Pre-existing (the palette always listed builtins), but D3 is what makes the palette worth opening, so it became reachable. |
| **D9** | **A change of active server clears the command cache**, in the same block where `StoreController` empties its own state — deferred to a microtask, because that listener runs inside Riverpod's refresh pass and writing to *another* provider there is what poisons the graph. | The store already documents why server A's data must never show under server B, and project ids are host-local (`RepoInfo(id: name…)`) — so two desktops with a same-named repo would serve each other's palettes. Worse than ordinary staleness (D5), because this cache is *persisted* and would survive a restart. Clearing rather than server-scoping the key: a switch is rare, and the first session on the new desktop refills it. |
| **D10** | **A worktree that leaves the repo snapshot takes its starter draft, picks and staged images with it** ([pruneStarterDrafts], called from `desktopSessionPruneProvider` right after `closeGroupsForDeletedWorktrees`). A **closed tab does not**. The key therefore carries the project id, `\u0000`-separated, and the guards are **per repo**: a project missing from the snapshot is unknown, and a repo reporting no worktrees is mid-refresh *or not a git repo at all*. | These three key spaces are non-`autoDispose` by design (that is what survives the tab switch) and nothing ever dropped them: a staged screenshot for a wrapped-up worktree held megabytes for the life of the process. A closed tab is the wrong trigger — D1 promises the draft is still there when it is reopened. The project id is in the key because a worktree path cannot say which repo owns it (a linked worktree lives nowhere near its repo), and the separator is `\u0000` (as in `cached_commands.dart`) rather than `:`, which is legal in both halves: a third review showed that with projects `a` and `a:b`, `a:b`'s key read back as project `a` with a path `a` does not list, and the prune deleted a live draft. **Review caught the first version guarding globally** — bail out of the whole pass if *any* repo looked unpopulated — which `repo_service.ts` turns into "one non-git project silently disables pruning entirely", since a non-git project always reports `worktrees: []`. `closeGroupsForDeletedWorktrees` guards per repo for exactly this reason. Must run in `afterPass`: writing to other providers during a build is a Riverpod assertion, which the first version of the test caught. |

## Verified against the real agent (not just unit tests)

The premise of D3–D5 — that a populated palette actually *runs* the skill when it is the first
message of a fresh session — was traced through all three hops rather than assumed:

1. makit sends the plain text `/skill:foo args` in `send.message` → ACP `session/prompt`.
2. `pi-acp` (`dist/index.js`): `prompt()` matches a leading `/`, finds no **pi-acp** builtin
   (`compact`, `session`, `name`, `steering`, `follow-up`, `changelog`, `export`, `autocompact`),
   and falls through to `session.prompt(message, images)`; `expandSlashCommand` leaves a `skill:`
   name untouched (it only expands *file* commands), so the text reaches pi intact.
3. pi (`dist/core/agent-session.js`): `prompt()` defaults `expandPromptTemplates` to **true**, and
   `_expandSkillCommand` rewrites `/skill:foo` into the full `<skill name=…>` block (line 954);
   `expandPromptTemplate` does the same for `/template`.

Two facts worth recording from that read:

- **Extension commands never reach the palette at all** — pi-acp advertises with
  `includeExtensionCommands: false`, so the cache cannot serve one. Correct by construction, not by
  luck.
- **Skill commands are a pi-acp toggle** (`enableSkillCommands`, default true, resolved per `cwd`).
  A user who turns it off simply gets no `skill:` rows — the cache stores what was advertised.
- pi-acp emits `available_commands_update` from a `setTimeout(0)` *after* `session/new` returns, on
  the result of pi's `get_commands`. That is precisely why a cache (not a synchronous read) is the
  right shape, and why the very first session in a project populates the palette a beat late.

## Phasing

- **P1 (this change)** — D1–D7: the draft, the harness and its picks survive a tab switch, the palette is
  populated from the per-project cache, attachments ride the spawn.
- **P2 (follow-up spec)** — the server-side probe: extend `capability_cache.ts` to persist commands
  under `agentId + fingerprint + cwd`, probing in the real worktree and waiting briefly for
  `available_commands_update`. That covers the case P1 structurally cannot — a worktree in which
  this harness has **never** run — and serves the phone too. P1's client cache is then a warm
  fast path in front of it, not a competitor.

## Non-goals

- Marking cached commands as possibly stale (D5) — explicitly accepted.
- Remembering the harness/model picks *past* a started session (D2 clears them): that is a sticky
  per-worktree harness preference, a different feature.
- Any change to the live pane's composer behaviour, or to mobile (which has no starter pane).
- Inline ACP image blocks — still SPEC-33's deferred phase.
