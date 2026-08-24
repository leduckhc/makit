# SPEC-docs-scoping-and-board-rework — docs-scoping-and-board-rework

**Status:** delivered · **Priority:** P1 · **Surface:** app (phone + desktop)
**Depends on:** [SPEC-doc-preview](./20260809-004600-SPEC-doc-preview.md)

---

## Goal

A worktree's docs glyph must open that worktree's docs. Today it opens the
host-wide board, so a badge that reads `7` produces a list of 420. This spec
scopes the entry point, makes widening deliberate, and makes the global board
scannable.

SPEC-doc-preview stays correct: a host-wide index and a global board are still
the right model. Only the door from the worktree row is wrong.

## Problem

`app/lib/ui/home/worktree_row.dart:387` builds `_WorktreeDocsGlyph` from
`docsForWorktreeProvider(worktree.path)`. It hides itself when that worktree owns
no docs, and it prints that worktree's count. Then `onTap` calls
`context.go(kRouteDocs)` and drops the scope.

Three consequences:

1. The count is a false promise. The glyph says `7`, the screen shows every doc
   on the host. On milan-vps that is 420 files across two repos; a Mac with 12
   worktrees reaches thousands.
2. It contradicts `docs/UX.md` §Ports, which defines the row-glyph contract:
   "the first tap lists the ports, the second opens one port's facts". The ports
   glyph on the same row obeys it and passes `worktreePath` + `branch` to
   `showWorktreePortsSheet`. Docs is the only row glyph that does not.
3. `context.go` replaces the route where the ports path pushes a sheet, so the
   back arrow behaves differently for two adjacent controls.

A second, independent defect: the filter chips are path-based —
`Mockups` = `mockups/`, `Specs` = `docs/` (`docs_filter.dart:20-21`). `rho` has
no `mockups/` directory, so that chip is permanently `0` in a repo the user
works in daily. This is the mistake SPEC-doc-preview D1 already found and fixed
for the *index* ("on `teachme` it found 3 of 69 documents"); the lesson never
reached the filters.

## Decisions

| | decision | why |
|---|---|---|
| **D1** | **The worktree glyph opens a scoped sheet**, `showWorktreeDocsSheet(context, worktreePath, branch)`, listing only that worktree's docs, mtime-descending. A second tap opens the existing preview. | Restores the row-glyph contract in `UX.md` §Ports and makes the badge honest. It mirrors `showWorktreePortsSheet` exactly, so there is one pattern for a row glyph, not two. |
| **D2** | **Widening is an explicit act.** The sheet ends with one row, `All docs in <repo>`, which opens the board. Nothing auto-widens. | The user tapped a worktree. Answering with the host is a non-sequitur. Widening stays available, but it costs a deliberate tap. |
| **D3** | **The board takes scope from the route, exactly like Ports.** `DocsScreen({repoId})` reads `?repo=<id>`, and `DocsFilter.thisRepo` is pre-selected when it is set (`_filter = repoId != null ? thisRepo : all`). The chip renders only when scoped (`showThisRepo:`). | This is not a new idea to design — `ports_screen.dart:47,63,141` and `router.dart:64` already do it, and `kRoutePorts` already carries `?repo=`. Reusing the idiom means the user learns one behaviour and widening is a chip tap, not a hidden gesture. An earlier draft of this spec invented a dismissible `rho ▸ main ✕` chip; that was rejected for duplicating a solved problem. |
| **D4** | **Unscoped with more than one repo, only the repo owning the newest doc stays expanded**; the others fold to a counted header (`makit · 200`). | Mirrors the one folding precedent that exists — `_systemExpanded = false` in `ports_screen.dart:69`, which folds noise so it "must not push a branch's dev server off screen". Recency picks the open group, so no `activeRepo` state has to be invented; the store has no such concept today. |
| **D5** | **A `Recent` group leads the board**, the 5 newest docs across the current scope, above the repo → worktree groups. | D5 of SPEC-doc-preview already argues "the doc you want is the one you just made", then buries it under grouping. Grouping answers *where*; recency answers *which*, and on a phone recency wins. |
| **D6** | **Filter chips become `All` / `This repo` / `Markdown` / `Pages` / `Changed`**, the kind ones from `DocInfo.kind`, which the wire already carries. The path chips `Mockups` and `Specs` are removed. | A chip must never be dead in a valid repo. `kind` is a property of the file; `mockups/` is a property of one repo's layout. The set mirrors `PortsFilter { all, thisRepo, … }`. No protocol change is needed. |
| **D7** | **Folder chips, if they return, must be derived** from the top-level directories the scope actually contains, never hardcoded. | Records why D6 removed them, so a future change does not re-add a hardcoded list. |

## Non-goals

- No change to the index, the wire protocol, or `docs.watch` ref-counting.
- No full-text search. Search stays over title and path (SPEC-doc-preview P1).
- No new event kind. `DocInfo.kind` already exists, so D6 is app-only.
- No change to the desktop popover. It shares only `docMatchesQuery`, not the
  chips, so D6 does not reach it. (An earlier draft of this spec claimed the
  popover shared the filter chips. It does not — verified in
  `docs_popover.dart`, which references no `DocsFilter`.)

## Verification

| claim | test |
|---|---|
| The glyph opens a scoped sheet, not the board | `app/test/ui/home/worktree_docs_glyph_test.dart` — taps the glyph, expects the sheet header and the worktree's branch, and expects `DocsScreen` `findsNothing`. Non-vacuous because the harness registers a real `kRouteDocs → DocsScreen` route, so a regression to `context.go` would build it. |
| The sheet lists only that worktree's docs, and its row count equals the badge | `app/test/ui/docs/worktree_docs_sheet_test.dart` — three docs across two worktrees (2 + 1); reads the badge from `docsForWorktreeProvider`, expects that many `DocRow`s, and expects the other worktree's title absent. |
| `All docs in <repo>` opens the board with `?repo=<id>` | `app/test/ui/docs/docs_scope_chip_test.dart`. |
| Scoped, `This repo` is pre-selected; unscoped, the chip is absent | same file — asserts both directions, so the chip cannot appear unscoped. |
| Unscoped with two repos, only the repo owning the newest doc is expanded | `app/test/ui/docs/docs_board_default_scope_test.dart`. |
| `Recent` holds the 5 newest in scope, newest first | `app/test/ui/docs/docs_filter_test.dart` (pure). |
| Kind chips filter by `DocInfo.kind`, and no chip is dead in a repo without `mockups/` | `app/test/ui/docs/docs_filter_test.dart` (pure). |

Test paths follow this repo's convention, `app/test/ui/<area>/`. An earlier draft
of this table put them at `app/test/`, which no UI test in this repo does.

App-only, so the stub e2e gate does not apply. Verified: `flutter analyze` →
`No issues found!`; `flutter test` → 3240 passed, 11 pre-existing skips.
