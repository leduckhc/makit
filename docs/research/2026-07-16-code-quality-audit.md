# Code Quality Audit — makit (whole codebase)

- **Date:** 2026-07-16
- **Base commit:** `954e2f7`
- **Scope:** ~9.4k lines TypeScript (`server/src`) + ~28k lines Dart (`app/lib`), non-test source read in full by four parallel reviewers.
- **Method:** "Thermo-nuclear" quality review — ambitious structural simplification, not cosmetic nits. Server typechecks clean (`pnpm typecheck` → 0). The 5 highest-stakes findings were verified against source before inclusion.

## Overall assessment

The architecture is **above average**: a pure `foldEvents` reducer, sealed `ChatItem`/`Decoded` hierarchies, injected transport seams, an immutable pane tree, and fixture-backed codec contract tests. Problems are **concentrated, not pervasive** — one real correctness defect, duplicated protocol/transport knowledge across parallel structures, a chunk of dead abstraction, and a few grab-bag files approaching 1k lines.

**Verdict: REQUEST CHANGES** — two independent blockers (B1, B2) below.

> Legend: 🔴 blocker · 🟠 high · 🟡 medium. "*(verified)*" = confirmed against source during this audit.

---

## 🔴 Blockers

### B1 — Multi-pane composer shares one app-lifetime `FocusNode` *(verified)*

- **Where:** `app/lib/desktop/chat/composer_focus.dart:8`, consumed at `desktop_chat_pane.dart:219`, driven at `keymap_scope.dart:162`.
- **Problem:** `desktopComposerFocusProvider` is an app-lifetime singleton `FocusNode`. Every `_PaneLeafView` (`pane_tree_view.dart:267`) renders a `DesktopChatPane` whose `Composer` binds that same node. Splitting two live sessions side-by-side → two `TextField`s attach to one `FocusNode` → **illegal double-attach** (debug assertion; release = undefined focus). Breaks the headline pane-split feature (#65). The existing pane test only pins one session, which is why it slipped.
- **Fix:** per-leaf focus node (`Provider.family` keyed by leaf id, or `DesktopChatPane` owns it in `State`). Route "focus composer" to the *active* leaf. Add a two-bound-sessions widget test.

### B2 — Dead `ToolRenderer.card` layer masquerading as live, with a lying doc comment *(verified)*

- **Where:** `app/lib/ui/session/tool_renderers.dart:53, 55-64, 67-137` + every `subtitle()` override.
- **Problem:** The transcript renders via `ToolCallCard`, which only reads `renderer.icon` + `toolDisplayName`. **Zero call sites** invoke `renderer.card(...)` or `renderer.subtitle(...)`. So `card()`, `_DefaultCard`, `inlineInteractive`, and every `subtitle()` override (~130 lines) are dead — yet the library doc (lines 12-16) claims "the card view is shown inline in the chat transcript." It is not.
- **Fix:** delete the card/subtitle/inlineInteractive surface; `ToolRenderer` collapses to `{name, displayName, icon, detail()}`. Also delete the redundant `_AskUserQuestionRenderer('AskUserQuestion')` (line 578) — the resolver already does a `toLowerCase()` fallback (`:590`).

---

## 1. Structural regressions & missed "code judo"

### S1 — Three server adapters triplicate subprocess transport + crash-guard (~120 lines)

- **Where:** `adapters/pi.ts:159-260`, `adapters/acp.ts:420-475`, `adapters/codex.ts:370-455`.
- **Problem:** All three reimplement: spawn with piped stdio, prefixed stderr forwarding, the verbatim "settle-once, buffer exit code until `onExit` registers" dance, the copy-pasted swallow-`'error'` comment (×3), and an LF-only line splitter (`bindLfLines` in pi.ts, re-inlined in codex.ts). This is a *transport* invariant ("a bad agent must never kill the daemon; stdout is LF-delimited JSON"), not a per-agent concern.
- **Remedy:** extract one `spawnLineProcess()` (`adapters/child_transport.ts`); `CodexTransport`/`AcpTransport` become aliases; `defaultConnect` shrinks to ~3 lines each.

### S2 — No shared adapter base: status/turn/approval state machine triplicated

- **Where:** `adapters/acp.ts:88-92,155-175,232-260`, `adapters/codex.ts:60-66,150-175,310-330`.
- **Problem:** ACP and Codex hand-roll the identical "turns-in-flight + pending-approvals → running/idle" machine with slightly different wording — the drift that produces "stuck spinner" bugs in one agent but not another. The twin `acp-map.ts`/`codex-map.ts` (shared `emit` helper, `startedTools` set, bottom-of-file title extractor) imply a parallel adapter base that doesn't exist.
- **Remedy:** `abstract class SubprocessAdapter` owning `emitEvent`/`handleExit`/`exited` + a shared `TurnStatusTracker`. Give pi a `pi-map.ts` so all three agents share the `Adapter + Mapper` shape (this is why pi.ts is 200 lines larger).

### S3 — Elicitation/permission→UICall policy duplicated & drifting (acp vs codex)

- **Where:** `adapters/acp.ts:295-360`, `adapters/codex.ts:255-300`, plus `describePermission`/`describeCommand`.
- **Problem:** Both `handleElicitation` encode the same "url→confirm / single-field→input / multi→decline" policy, differing only in response shape. Business logic that has already diverged.
- **Remedy:** one pure `mapElicitation(...)` + `confirmViaUser(...)` in `adapters/interaction.ts`.

### S4 — `foldEvents` copy-pastes the same streaming accumulator three times

- **Where:** `store/models.dart:676-820` (cases at 692/707, 728/750, 765/788).
- **Problem:** message / thinking / tool paths are the same "find in-progress by id → append delta / create-on-first / finalize" algorithm (~90 lines). Message and thinking blocks are near-identical down to comments.
- **Remedy:** one generic `_upsertStream<T>(items, index, id, create, append)` → three ~4-line call sites. Pure and unit-testable.

### S5 — Desktop forks the mobile transcript renderer instead of sharing it

- **Where:** `desktop_chat_pane.dart` `_buildItem` + `_ThinkingLine`/`_ErrorBanner`/`_WorkingIndicator` vs `ui/session/session_screen.dart`.
- **Problem:** Desktop re-implements the item-dispatch switch and three item widgets that already exist in mobile (byte-for-byte behavior, cosmetic padding delta). The class doc claims it renders identically — make that true by construction.
- **Remedy:** shared `ui/session/chat_transcript.dart` exposing `chatItemWidget(...)` + the three item widgets. Deletes ~120 lines of fork.

### S6 — Pane-tree has ~9 hand-rolled recursive walks that collapse to 2 combinators

- **Where:** `pane_tree_controller.dart` (`_activeLeaf`, `_pinLeaf`, `_siblingFirstLeafId`, `_ratioOf`, `_clearSession`), `pane_node.dart` (`_findLeaf`, `firstLeafId`, `containsLeaf`).
- **Problem:** `_pinLeaf`/`_clearSession` are both "rebuild tree transforming matching leaves"; `_activeLeaf`/`_findLeaf`/`_ratioOf` are all "first leaf matching predicate."
- **Remedy:** add `mapLeaves()` + `firstLeafWhere()` to `pane_node.dart`, delete the rest. (Bonus: fixes `setRatio` recursing into both children post-match.)

---

## 2. Spaghetti / branching / fragile invariants

### P1 — `send.message` emits a `seq:0` event inline, bypassing `Session.record()` *(verified — correctness bug)*

- **Where:** `server.ts:287-294`.
- **Problem:** On draft-promotion failure it hand-builds `session.emit("event", {seq:0, ...})` — **unpersisted, seq collides with/precedes every real event**, so a reconnecting client mis-orders or drops it. Also a layering leak (feature logic in the WS handler).
- **Remedy:** move promotion into the manager; route the error through `Session.record()` for a real seq.

### P2 — Full sessions-snapshot fan-out on every streaming delta

- **Where:** `server.ts:576-585` (`wireSession`).
- **Problem:** `broadcastSessionsSnapshot()` serializes every session DTO to every client *per token*. O(clients × sessions) per delta — a scaling cliff.
- **Remedy:** re-broadcast only on DTO-visible changes (title/status/preview), not on every `event`.

### P3 — `listRepos` fully sequential

- **Where:** `manager.ts:392-448`; `git.ts:150-156`.
- **Problem:** per project, serial `isGitRepo→detectBranch→listWorktrees`, then serial `diffStat`+`gh findOpenPr` (5s timeout) per worktree. Independent read-only shells on the hot home path.
- **Remedy:** `Promise.all` over projects and worktrees; bound concurrency if needed.

### P4 — Pending-draft = 6 nullable fields bolted onto `Session`

- **Where:** `session.ts:60-77`, mutated across `manager.ts`.
- **Problem:** draft→started lifecycle smeared across mutable optionals; invariants enforced by convention.
- **Remedy:** discriminated union `{phase:"draft"} | {phase:"started"}`; `markStarted` becomes a transition.

### P5 — `_onFrame` length-heuristic refresh

- **Where:** `store/store.dart:283-292`.
- **Problem:** infers "server dropped a repos snapshot" from `projects.length > repos.length` on the hot frame path — can spin a refresh loop.
- **Remedy:** let `project.add/remove` own refresh; drop the heuristic.

### P6 — Raw-string `risk` / tool-status switched on in UI

- **Where:** `store/models.dart:627,644`; `tool_call_card.dart:18-25`; `tool_renderers.dart:144,502,635`.
- **Problem:** `'safe'/'risky'/'destructive'` magic strings with silent `_` fallback; tri-state status recomputed from two nullable fields at 3 sites; the `deltas.isNotEmpty ? join : output` idiom copy-pasted 3× with *inconsistent* precedence. The codebase already models `SessionStatus`/`ApprovalPolicy` as enums.
- **Remedy:** add `ToolRisk`/`ToolStatus` enums (parsed at the model boundary) and a `ToolCallItem.resultText` getter.

---

## 3. Boundary & type problems

### T1 — `Envelope as unknown as UIResponse`, twice, no validation

- **Where:** `index.ts:306, 339`.
- **Problem:** a malformed/hostile device response propagates `undefined` into agent replies. The double-cast is the tell that two unrelated types are welded.
- **Remedy:** add `decodeUIResponse(env)` in the codec (mirror `decodeSessionEvent`); closes an untrusted-input gap.

### T2 — Wholesale `eslint-disable no-explicit-any` in all three adapters *(verified)*

- **Where:** `adapters/pi.ts:17`, `adapters/acp.ts:17`, `adapters/codex.ts:16`.
- **Problem:** `any` end-to-end, not just at the `JSON.parse` boundary.
- **Remedy:** define minimal wire interfaces for the frames actually consumed; confine `any` to the parse seam.

### T3 — Dead `toJson` surface in `control_types.dart` (~70 lines)

- **Where:** `control/control_types.dart:158,215,253,311,342,472`.
- **Problem:** the control client is decode-only; **zero callers**.
- **Remedy:** delete (keep `fromJson`). Halves the change-surface per control verb.

### T4 — `srv.response` shaping duplicated in widget + notifications

- **Where:** `ui/widgets/srv_request_handler.dart` vs `notifications/notification_request.dart:88`.
- **Problem:** both hand-build `{'kind':'confirmAction','approved':…}` / `{'kind':'askUserQuestion',...}`. Untested drift risk on a server-driven-dialog boundary.
- **Remedy:** one shared `SrvResponse` builder used by both paths.

### T5 — Dead protocol surface

- **Where:** `protocol.ts:48` (`session.action_error`, never emitted); `protocol.ts:154-166` (`CmdKind` drifted from actual router registrations).
- **Remedy:** wire or delete.

---

## 4. File size / decomposition

| File | Lines | Action |
|---|---|---|
| `desktop/chat/desktop_chat_pane.dart` | 919 | Split → `pane_header.dart`, `harness_picker.dart`, shared transcript widgets (S5). Leaves ~250 lines. |
| `store/models.dart` | 824 | Split `chat_items.dart` (ChatItem tree + `foldEvents`) out of DTOs (~360 lines). Pairs with S4. |
| `ui/session/tool_renderers.dart` | 922 → ~660 after B2 | Extract pure `tool_result_text.dart` (JSON splitter that silently `return raw`s — deserves tests) and `diff_view.dart` (unify two near-identical diff-line renderers). |
| `ui/home/home_screen.dart` | 820 | Decompose; move `_RepoCard` new-session/attach/remove orchestration to the store layer. |
| `ui/widgets/srv_request_handler.dart` | 737 | Protocol logic living in `ui/widgets/` — split dispatch/queue controller from dialogs. |
| `server.ts` | 687 | Command router is ~330 lines of inline handlers → `ws/commands/*`. |
| `manager.ts` | 647 | Extract `RepoService` (localizes P3) + `AgentFactory`. |
| `index.ts` | 485 | Split `runServe()` out of the ~330-line `main()`. |

---

## 5. Recurring desktop duplication (#56/#59/#61/#65 velocity debt)

- "Coming soon" implemented **7×**, reset (↺) button **6×**, `DragToMoveArea` strip **7×**, sidebar-toggle button **3×** (inconsistent `top:3` vs `top:7`).
- **Remedy:** promote `ComingSoonRow`, `SettingsResetButton`, `TitleBarStrip`, `SidebarToggleButton`.
- The settings registry `items` list is a drifting second source of truth (already mismatched for `appearance.text_code`) — treat it as a *tested* search-only index; `SettingsSection.availability` is dead.

---

## Recommended priority order

1. **B1** — per-leaf composer focus node + test *(correctness; breaks multi-pane)*
2. **P1** — route draft-failure through `Session.record()`, kill the `seq:0` event *(correctness)*
3. **B2 + S4** — delete dead `ToolRenderer.card` layer; collapse `foldEvents` accumulators *(~220 lines deleted, honest abstraction)*
4. **S1 + S2** — shared subprocess transport + `SubprocessAdapter` base *(~120 lines deleted, kills adapter drift)*
5. **P2 + P3** — stop per-token snapshot fan-out; parallelize `listRepos` *(the two real perf cliffs)*
6. **T1 + T3** — validate `srv.response` at the boundary; delete dead `toJson` surface *(trust boundary + ~70 lines)*

Items 1–2 are correctness blockers. 3–4 are the highest-leverage structural simplifications (~340 lines deleted while making adapters symmetric and the reducer single-path). 5 protects scale, 6 protects the trust boundary. None require a redesign — the underlying architecture is sound.

---

## Appendix — verification performed

The following claims were confirmed against source during this audit (not just reported by reviewers):

- **B1:** `desktopComposerFocusProvider` is a singleton; both `keymap_scope.dart:162` and `desktop_chat_pane.dart:219` bind it; each `_PaneLeafView` renders a `DesktopChatPane` with its own `Composer`.
- **B2:** no `.card(` / `renderer.subtitle(` call sites in `app/lib`; `_DefaultCard` reachable only via the dead `card()`; double `_AskUserQuestionRenderer` registration real; resolver does `toLowerCase()` fallback at `tool_renderers.dart:590`.
- **P1:** `server.ts:287` emits `{seq:0, ...}` inline via `session.emit`, bypassing `record()`.
- **S1/S2:** `acp-map.ts` and `codex-map.ts` share `emit` helper, `startedTools` set, and a bottom-of-file first-line/title extractor.
- **T2:** file-level `eslint-disable @typescript-eslint/no-explicit-any` atop all three adapters.
