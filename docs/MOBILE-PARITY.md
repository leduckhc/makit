# Mobile parity backlog

Working notes for closing the gap between the mobile surface and the desktop
app. Branch: `feat/mobile-parity`.

## The thing to understand first

`app/lib/ui/` is **not** "the mobile app". It is both the mobile surface *and*
the shared widget library that `app/lib/desktop/` composes. So several features
that look like mobile gaps are already at parity by construction:

| Assumed behind | Reality |
|---|---|
| Transcript, scroll anchoring (SPEC-21) | Shared. Both surfaces wire `findChildIndexCallback` — `ui/session/session_screen.dart`, `desktop/chat/desktop_chat_pane.dart` |
| Expandable tool rows + durable fold (SPEC-24) | Shared `expandedTranscriptRowsProvider` |
| Inline `ask_user` cards (SPEC-25) | Shared `ui/session/ask_card.dart` |
| Media / GIF (SPEC-22), diffs | Shared `ui/session/media_view.dart`, `diff_view.dart` |
| Model picker + per-model flyout (SPEC-31) | Shared. Mobile = `showModelPickerSheet`, desktop = `MenuAnchor` |

The real lag is the **chrome around** the shared widgets, and it is UI-only —
the store and wire protocol already support every item below.

## Genuinely desktop-only

`desktop/chat/pr_bar.dart`, `desktop/chat/composer_draft.dart`,
`desktop/chat/archived_sidebar_view.dart`, exited/resumable session gating,
`desktop/settings/**` (12 sections), `desktop/chat/github_budget_button.dart`,
`keymap_scope`, `tray/`, `open_in_ide`, split/tab/groups (SPEC-28/30).

Desktop-only *by nature*: tray, open-in-IDE, split panes, tab groups.

## Priority order

Ranked by how often a phone user hits the gap, not by size.

1. **Push wake on force-quit (SPEC-07)** — M. Registration exists, no
   killed-app handler, so notifications are silent after a force-quit. Highest
   impact (a remote control that cannot notify fails its core job) but needs a
   physical device + Xcode to verify.
2. **PR bar (SPEC-23)** — ✅ *done (visibility only)*. The session screen's
   subtitle line now carries a `SessionPrChip` (`#42` + CI verdict) that opens a
   shared PR sheet (`ui/widgets/pr_sheet.dart`: state, draft, conflicts,
   unresolved threads, per-check list, open-on-GitHub); the home screen's
   `PrPill` opens the same sheet. Desktop's PR *actions* stay desktop-only — they
   resolve canned prompts through the preferences/prompt-template layer, which
   mobile does not carry.
3. **Composer draft persistence (SPEC-27)** — ✅ *done*. `composer_draft.dart`
   moved from `desktop/chat/` to `ui/composer/` (pure move) and the mobile
   composer now seeds from / writes to it, so a draft survives a route pop. The
   composer is also keyed by session id — it previously carried one session's
   text into another when the screen was rebound in place.
4. **Settings** — L. Mobile has `settings_screen.dart` +
   `notification_settings.dart` and a literal "Coming soon" tile, vs 12 desktop
   sections. Breadth, but low frequency: mostly one-time setup.
5. **Device / server management** — L. No mobile analogue of desktop's
   `devices_screen`, `status_screen`, `sessions_screen`, `session_log_screen`.

Low value on a phone: GitHub budget indicator (SPEC-32) — an icon at most.

## Repo list vs. the desktop sidebar

Audited `desktop/chat/desktop_sidebar.dart` against the mobile home. Done:

- **every worktree is listed**, not only those with a live session — the row
  used to hard-return an empty box, hiding the branch you most want to start a
  session on. Flipped the assertion in `home_screen_test.dart` that demanded the
  old behaviour.
- **collapsible repo card** (tap the header) and **"Show N more"** past five
  worktrees, the sidebar's cap. Cards are keyed by repo id *and* the list uses
  `findChildIndexCallback`, without which a reordering repo loses its state.
- **foldable worktree row**: the caret and the row both toggle. The sidebar
  splits those two gestures because its row also navigates; a phone has no
  worktree canvas, so the whole row is free to be the target.
- **branch age** (`3d ago`) under the branch, from the now-shared
  `branchAgeLabel`.

Still sidebar-only, deferred by decision:

- ~~**worktree actions**~~ — ✅ done: long-press a worktree row opens rename /
  delete in a sheet, with desktop's guards (no rename on primary, detached or
  open-PR; no delete on primary), shown disabled-with-reason rather than hidden.
- ~~**New worktree**~~ — ✅ done: a repo-card menu item; pick the fork point, the
  server names the branch, and no session is started.

Also done since:

- **Appearance settings** — theme mode + text scale on the phone. The
  preferences layer moved from `desktop/settings/prefs/` to `store/prefs/`, so
  both surfaces share one diff-only overrides format. Storage key is still
  `desktop_settings_overrides` — renaming needs a migration.
- **PR actions in the composer** — the canned prompts (fix CI, resolve comments,
  commit and push, push, pull) live in the PR sheet, inserted into the composer
  and never auto-sent. `pr_actions.dart` moved to `ui/widgets/`, so prompt
  resolution and any desktop override is the same code path.
- **Repo list density** — the list now follows the sidebar's structure and
  information density (type hierarchy, indentation ladder, sub-rows, tighter
  chrome) in the phone's glass skin, with every interactive row held at or above
  the 44pt touch floor (`kTouchRow`, enforced by
  `test/ui/home/repo_list_density_test.dart`).

Still open:

- **Settings breadth** — desktop has 8 sections / 38 entries but only 13 real
  preferences, and most are desktop-only (sidebar width, preferred IDE,
  auto-split threshold). Mobile now covers the two that matter (theme, text
  scale); the PR-prompt overrides are readable but have no mobile editor yet.
- **SPEC-07 push wake on force-quit** — highest impact, device-gated.
- **Device / server management** — no mobile analogue of `devices_screen`,
  `status_screen`, `session_log_screen`.

Not portable by design: boards/groups quick-pin, drag-session-to-pane, worktree
selection highlight, sidebar fold, title-bar strip, server-profile badge. Mobile
also keeps what desktop lacks — swipe-to-quit, resume-past-session,
pull-to-refresh.

## Done on this branch

- `fix(app): hide dead sessions on the mobile home (SPEC-29)` — exited sessions
  are dropped unless resumable, matching the desktop sidebar.
- `feat(app): archived-sessions screen on mobile (SPEC-29)` — `/archived`,
  grouped by repo, restore + empty/error/retry states.

## Open decision — worktree visibility

**A branch with uncommitted changes but no session is invisible on mobile.**

`ui/home/worktree_row.dart` returns `SizedBox.shrink()` for any worktree with no
live session ("Only surface worktrees with a live session (strict)", from
b07ec196). But:

- `ui/home/repo_card.dart` says empty non-primary worktrees should be hidden
  *behind* the primary + active ones — collapsed, not erased.
- SPEC-11 says home should show "the active worktrees (feature branches) and how
  big each change is".
- Desktop shows them, collapsed at 5 behind a "Show N more" toggle
  (`desktop/chat/desktop_sidebar.dart`).

A fix (move the visibility decision into `RepoCard`, always render
primary/live/dirty worktrees, collapse the quiet ones behind "Show N more") was
implemented and tested, then reverted because it flips the explicit assertion at
`app/test/home_screen_test.dart:113`. That assertion is a product decision, so
it needs a human call before reinstating.

Backups: `/tmp/makit-repo-list-wip.patch`,
`/tmp/repo_card_worktree_collapse_test.dart.bak`.

## Verification

```sh
cd app
flutter analyze --no-pub     # must be clean; audit gate uses --fatal-infos
flutter test --no-pub
```

A fresh worktree needs `flutter pub get` once (`.dart_tool/` is gitignored).
