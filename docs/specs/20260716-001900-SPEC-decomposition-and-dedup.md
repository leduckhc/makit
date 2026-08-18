# SPEC-decomposition-and-dedup — File decomposition & desktop widget de-duplication

**Status:** Proposed · **Priority:** P2 · **Source:** `docs/research/2026-07-16-code-quality-audit.md` §4 (file size), §5 (desktop duplication)
**Scope:** file splits + shared-widget extraction. Behavior-preserving. **Coordinate ordering** with SPEC-app-chat-simplification (app chat) and SPEC-server-adapter-consolidation (adapters) — do those first where they overlap, or rebase.

---

## 🚦 Branch & worktree gate (NO GO if not met)

This spec **MUST** be implemented in a **new git worktree branched from `chore/code-quality-review`**, and its **pull request MUST target `chore/code-quality-review`** (not `main`).

- Base branch: `chore/code-quality-review`
- PR target branch: `chore/code-quality-review`

If either condition is not satisfied, **this spec is NO GO**.

```bash
git fetch origin chore/code-quality-review
git worktree add ../spec-19-decomp -b spec-19/decomposition origin/chore/code-quality-review
```

---

## Goal

Bring oversized grab-bag files back under a healthy size boundary and delete the
recurring copy-pasted desktop chrome that accreted during #56/#59/#61/#65. No
behavior change — pure moves + shared-widget extraction.

## File decomposition (§4)

Keep every changed line traceable to a move; do **not** "improve" adjacent code.

| File | Lines | Split into |
|---|---|---|
| `app/lib/desktop/chat/desktop_chat_pane.dart` | 919 | `chat/panes/pane_header.dart` (`_PaneHeader`, `SessionActionsMenu`, `sessionPaneTitle`, `_showSidebarButton`, `_UnfoldStrip`); `chat/harness_picker.dart` (`_HarnessPicker`, `_HarnessCard`, `_WorktreeStartView`); shared transcript widgets → `ui/session/` (see SPEC-app-chat-simplification S5). Remainder ~250 lines. |
| `app/lib/store/models.dart` | 824 | `store/chat_items.dart` (ChatItem tree + `foldEvents`) — pairs with SPEC-app-chat-simplification S4. ~360 lines out. |
| `app/lib/ui/session/tool_renderers.dart` | 922 (→~660 after SPEC-app-chat-simplification B2) | `ui/session/tool_result_text.dart` (pure `extractToolResultText`/`_splitJsonValues`/`_valueString`, no Flutter import, **add tests** — it silently `return raw`s on decode failure); `ui/session/diff_view.dart` (`DiffText` + a unified `DiffRow` merging the two near-identical diff-line renderers). |
| `app/lib/ui/home/home_screen.dart` | 820 | `home/repo_card.dart`, `home/worktree_row.dart`, `home/session_tile.dart`, `home/new_session_sheet.dart`. (Moving `_RepoCard`'s orchestration to the store is a separate concern — out of scope here; keep the move mechanical.) |
| `app/lib/ui/widgets/srv_request_handler.dart` | 737 | Split the dialogs (`_AskWizard`, `_OptionTile`, `AlertDialog` builders) into `ui/widgets/srv_dialogs/`; the response-shaping is unified in SPEC-boundary-hardening T4. |
| `server/src/server.ts` | 687 | Move the ~330-line inline handler body of `buildCommandRouter` into `ws/commands/*.ts` grouped by domain (session, project, worktree, repo), each exporting `register(router, deps)`. `server.ts` keeps only wiring. |
| `server/src/manager.ts` | 647 | Extract `RepoService.listRepos()` (all git/gh enrichment — localizes SPEC-server-hotpath-and-state P3) and an `AgentFactory` for `buildAdapter`. |
| `server/src/index.ts` | 485 | Split `runServe(opts)` out of the ~330-line `main()`, leaving `main` as subcommand routing. |

## Desktop widget de-duplication (§5)

Confirmed duplication counts from the audit:

- **"Coming soon" ×7, reset (↺) button ×6, `DragToMoveArea` strip ×7,
  sidebar-toggle button ×3** (with inconsistent `top:3` vs `top:7`).
- **Fix:** promote single shared widgets:
  - `ComingSoonRow({icon, title, subtitle})` (replaces `_ComingSoonRow`,
    `_TelemetryRow`, `_PerTypeMuteRow`, whole-section `ComingSoon`).
  - `SettingsResetButton({visible, onPressed})` (replaces the inline `_ResetButton`
    copies in `_ThemeRow`, `shortcuts_section`, `notifications_section`,
    `server_devices_section._EndpointRow`).
  - `TitleBarStrip({leading})` owning the `DragToMoveArea` + traffic-light inset
    (replaces the strips in `desktop_sidebar._Header`, `pane_tree_view`,
    `desktop_chat_pane._UnfoldStrip`, `settings_nav_pane`).
  - `SidebarToggleButton({required bool collapse})` (replaces the 3 hand-rolled
    `Symbols.thumbnail_bar` buttons; standardize `iconSize:19`, 24×24 constraints,
    positioning).
- **Settings registry drift:** treat `settings_registry.dart` `items` as a
  **search-only index** and add a test asserting every `SettingsItem.id` resolves
  and its title matches a value actually rendered (already mismatched for
  `appearance.text_code`). Delete the dead `SettingsSection.availability` field
  (`_SectionList` never reads it) and collapse the single-method
  `SettingsSearchIndex` class into the `searchSettings` function (YAGNI).

## Verification (definition of done)

- Pure moves compile with no behavior change; `flutter analyze --fatal-infos`
  clean; `app/tool/audit.sh` passes; `cd server && pnpm typecheck && pnpm test`
  green.
- New unit tests for the extracted pure `tool_result_text.dart`.
- New test asserting settings-registry ids resolve (drift guard).
- Grep proves the shared widgets replaced the duplicated copies (no remaining
  inline `_ResetButton` / bespoke `DragToMoveArea` chrome).
- No file that was under 1000 lines is left over 1000; oversized files listed
  above are materially smaller.

## Non-goals

- **No logic changes** — orchestration-to-store moves (audit §UI 3.1–3.4) and
  the render/model changes are owned by SPEC-app-chat-simplification/SPEC-server-hotpath-and-state, not here. If a move
  collides with those specs, rebase rather than duplicate the change.
