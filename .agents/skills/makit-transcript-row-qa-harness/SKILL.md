---
name: "makit-transcript-row-qa-harness"
description: "Grade a makit transcript-row change (tool/thinking one-liners) on the real macOS app and iOS simulator using app/tool/tool_row_demo.dart, with measured pitch and contrast instead of eyeballing."
---
## When to Use
Use when a change touches a collapsed transcript row (ToolCallCard, ThinkingLine, chat_metrics tokens) and needs pixel-level sign-off on both platforms without a server, a paired device, or an agent binary. Do not use for flows that need real session state (approvals, queue, PR bar) — those need the stub server or pr_bar_demo.

## Procedure
1. Run the harness, not the app: `cd app && flutter run -d macos --debug -t tool/tool_row_demo.dart` and `flutter run -d "iPhone 17" --debug -t tool/tool_row_demo.dart`. It renders the seeded transcript through the real `chatItemWidget` + `transcriptRow`, so gutters, gaps and ellipsis are the product's.
2. Before every macOS run: `rm -rf .dart_tool/flutter_build build/macos/Build/Products/Debug`. Even then, verify the binary is fresh by reading the harness's own top-bar stamp (`tool one-liner · <brightness> · <width>pt`) — a stale macOS bundle silently ran with different State defaults than the source and made the first QA pass grade the wrong theme.
3. Find the window: `ps -eo pid,command | grep 'feat-.../app/build/macos.*MacOS/Makit'` then `cua-driver call list_windows '{}'` and pick this pid's window with height > 400. Several Makit instances (other worktrees, the user's own app) are always running.
4. Read geometry from the AX tree, not from pixels: `cua-driver call get_window_state '{"pid":P,"window_id":W}'`. Each row is one AXButton whose `frame.h` is the row pitch (tool row 31, thinking row 27) and whose `label` is the full semantics string (`'Run grep, head\ntook 3s\n3s'`). AX space equals Flutter logical px here — confirm by checking a row's `frame.w` against the harness's selected pane width.
5. Drive the harness by element token, which needs pid + window_id as well: `cua-driver call click '{"pid":P,"window_id":W,"element_token":"sXXXX:2","delivery_mode":"foreground"}'`. Tokens are re-issued on every snapshot, so fetch them immediately before each click. This is how you reach light/dark, 430/560/full, ruler, and how you expand a row.
6. Capture macOS while occluded by tiling `zoom`: request 357px-wide boxes stepping 500px in physical space (2x), paste into a canvas. Take two captures and compare — zoom lags the UI by seconds.
7. Capture iOS with `xcrun simctl io booted screenshot out.png` after `xcrun simctl ui <id> appearance dark` (a freshly erased sim boots light, which would make every colour claim wrong).
8. Grade contrast by compositing the token over the known flat surface and applying WCAG, then pin the result in `test/theme_contrast_test.dart`. A row glyph is a graphical object: the bar is 3:1, not 4.5:1.

## Pitfalls
- Hover cannot be driven this way. `move_cursor` produced no tooltip and not even the row's disclosure caret — Flutter never saw the pointer. Cover hover affordances with a widget test asserting the `Tooltip.message` and record it as a QA coverage gap.
- `find.text('Run echo')` stops matching once the row becomes a `Text.rich`; pass `findRichText: true`. Also note the row's leading `Icon` is itself a bare `RichText`, so scope a style probe with `find.descendant(of: find.byType(Text), matching: find.byType(RichText))`.
- A names-only shell payload makes fixtures collide: `echo a` and `echo b` both render `Run echo`, so anchor/scroll tests that find a specific row by label need one distinct command *name* per row (e.g. `tool$i --run`).
- Do not trust a single zoom frame; and stability alone is not proof a click landed, since a no-op click also yields a stable frame. Assert against a known-different prior state (the top-bar stamp works well).

## Verification
1. The harness top bar reports the brightness and width you intended — proof the bundle is not stale.
2. AX `frame.h` for every tool row equals the designed pitch, and thinking rows are 4 px shorter.
3. Both themes captured and read: dark from tiled `zoom`, light after toggling via element token.
4. `flutter analyze --no-pub` clean and each touched test file green when run individually (the full suite emits 11-24 flaky 'loading' errors that pass in isolation).
