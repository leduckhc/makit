---
name: "makit-capture-real-app-screenshots"
description: "Capture full-resolution screenshots of the real running makit Flutter app (macOS) for design review, without stealing the user's foreground or trusting a stale build."
---
## When to Use
Use when asked to design-review, screenshot, or visually verify makit's real Flutter UI on macOS — especially when web tooling (agent-browser, probe.js) does not apply, when the app window is buried under other windows, or when you must not steal the user's foreground.

## Procedure
1. Prefer an existing harness over the full app: `app/tool/pr_bar_demo.dart` renders the real PrComposerBar/PrDetailBody with the real theme and ~20 seeded PR states, needing no server or GitHub quota. `flutter run -d macos --profile -t tool/pr_bar_demo.dart` (profile = no debug banner).
2. Clear the build cache FIRST or the target and your code changes are both ignored: `rm -rf app/.dart_tool/flutter_build app/build/macos/Build/Products/Profile`.
3. Identify the real target window: `cua-driver call list_windows '{}'` and match on pid from `ps -eo pid,lstart,command | grep MacOS/Makit`. Several Makit instances typically run at once (the user's own app plus other worktrees) — never assume.
4. Capture with window-bound `zoom`, which works while the window is occluded and needs no foreground: `cua-driver call zoom '{"pid":P,"window_id":W,"x1":..,"y1":..,"x2":..,"y2":..}'` returns base64 in a *_b64 key.
5. Defeat zoom's 500px cap by tiling at scale 1.0: request 357px-wide boxes (357*1.4 = 500 covered px), step by 500 in covered space, paste into a canvas. 2880x1800 needs 24 tiles and stitches seamlessly.
6. Drive state changes with `click` + `delivery_mode:"foreground"`, then verify the new state by reading the AX text via `get_window_state` (pr_bar_demo prints its own `identity=… dot=… cta=…` model dump, which beats eyeballing pixels).
7. Measure contrast from the captured pixels, not from theme tokens: background = modal colour of the region; foreground = the pixel at the 98th percentile of luminance distance from it (a pixel-share threshold finds nothing, because anti-aliased glyph cores are a tiny minority). Then apply WCAG 2.1.
8. Test responsive behaviour by resizing with `set_window_frame` (requires BOTH pid and window_id) across several widths and re-capturing the same region.

## Pitfalls
- `flutter run -d macos --release|--profile -t <alt>.dart` silently reuses a cached Flutter bundle: it renders lib/main.dart AND omits Dart edits, even though macos/Flutter/ephemeral/Flutter-Generated.xcconfig correctly shows FLUTTER_TARGET=<alt>. Always `rm -rf app/.dart_tool/flutter_build app/build/macos/Build/Products/<Config>` first, then verify the running binary reflects HEAD by checking a label you just changed.
- `zoom` returns frames SEVERAL SECONDS behind the UI. This causes false negatives — you conclude a click did nothing when it worked. Capture repeatedly until two consecutive frames are byte-identical. Note that stability != change: if the click never landed the frame is also stable, so assert against a known-different prior state, not just stability.
- Targets MOVE after any layout-changing action. Inserting a prompt grows the composer and shifts the PR bar up ~45pt, so a cached coordinate then lands in the text area. Re-derive coordinates after every state change.
- AX element text is under `label` (sometimes `value`/`description`) and geometry under `frame` — NOT `title`/`bounds`. Probing the wrong key returns empty text and all-zero bounds, which looks like 'Flutter exposes nothing'. Separately, Flutter publishes its semantic tree only intermittently: one instance exposed all widget text, a later instance of the same binary exposed only the macOS menubar. Never depend on it; assert against pixels.
- Transient Flutter popup menus (the CTA caret menu) could not be driven at all: they do not open under synthesized clicks, and `delivery_mode:"foreground"` dismisses them by restoring the prior frontmost app. Large targets (list rows, 107x28pt buttons) do work. Budget for menus being untestable this way and fall back to widget tests, stating that as a coverage gap.
- Three coordinate spaces: `zoom` x1/y1/x2/y2 are PHYSICAL framebuffer px (2880x1800 for a 1440x900 window); `click`/`get_window_state`/`debug_image_out` use a THIRD space (1568x980 for that same window); `list_windows` bounds are LOGICAL points. Always confirm with click's `debug_image_out` crosshair before trusting a coordinate.
- `zoom` expands the requested box by 20% per side then downscales to <=500px wide. Request 357px-wide boxes for exactly 500px output at scale 1.0.
- `screencapture -l <wid>` fails ('could not create image from window') — the shell lacks the Screen Recording TCC grant; only the cua-driver daemon has it. And display-capture + crop races z-order, silently capturing whatever is on top (it grabbed unrelated private content twice). Prefer window-bound `zoom`, which works while fully occluded.
- A tile request outside the window bounds makes `zoom` return non-JSON; make the stitcher skip failed tiles instead of crashing.
- Don't grade dev-harness chrome (pr_bar_demo's scene list, the 'What the derivation says' dump, the `run wrapUp` pills) as product UI.
## Verification
1. The running binary shows a label you changed at HEAD (e.g. a renamed CTA), proving the bundle is not stale.
2. A stitched capture has no visible tile seams and its dimensions equal the requested region.
3. Reported colour/contrast claims are reproducible from the saved PNG, not from theme tokens — cross-check one ratio by hand, since token lookups and rendered pixels genuinely disagree (a token-based reviewer reported 3.89:1 where the composite measured 5.53:1).
4. Captured images contain only the target window — no other app's content.
