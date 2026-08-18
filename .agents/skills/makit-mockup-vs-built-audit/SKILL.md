---
name: "makit-mockup-vs-built-audit"
description: "Simulate makit Flutter UI on macOS/iOS from widget tests and diff it against a mockups/*.html design reference, section by section."
---
## When to Use
Use when asked "how does X look on iOS/macOS", or to check whether an implemented makit feature matches its `mockups/<name>.html` reference. Works without a simulator, a device, or a running server.

## Procedure
1. Read the mockup's inline `<style>` tokens and the JS state objects (`const st={…}`, `ACTS`, `WRONG`, `#gaps`) — the visible HTML is generated, so the JS data is the actual spec. Check for an `as built` / `superseded` tag and the §"where this mock was wrong" table before reporting anything as a bug.
2. Write a scratch golden harness under `app/test/sim/`. Screenshot with `await expectLater(find.byType(MaterialApp), matchesGoldenFile('images/<name>.png'))` — `expectLater` returns a Future, and an un-awaited golden comparison reports nothing. Run `flutter test --no-pub --update-goldens test/sim/<file>.dart`. Set `tester.view.devicePixelRatio = dpr` BEFORE `tester.view.physicalSize = Size(logicalW * dpr, logicalH * dpr)`, with dpr 2 for macOS panes and 3 for iPhone (393pt); Flutter divides physicalSize by devicePixelRatio, so the wrong order gives the wrong viewport. Add `addTearDown(tester.view.reset)`.
3. In `setUpAll`, load real fonts or every glyph renders as an Ahem box: `/System/Library/Fonts/SFNS.ttf` registered under 'SF Pro Text' (the app's `kSansFontFamily`), 'Roboto' and '.SF NS', plus `assets/fonts/codicon.ttf`. Resolve the Phosphor fonts from the active package config — read `.dart_tool/package_config.json`, take the `phosphoricons_flutter` `rootUri`, and append `lib/fonts/Phosphor-<Weight>.ttf`, registered under `packages/phosphoricons_flutter/Phosphor<Weight>`. Never hardcode `~/.pub-cache/…/phosphoricons_flutter-1.0.0`: the pubspec pins `^1.0.0`, so a patch bump moves the path and the loader silently falls back to Ahem boxes.
4. Use the real theme (`makitDarkTheme`/`makitLightTheme`) and override `preferencesControllerProvider` with `PreferencesController.ephemeral()`; for mobile glass, override `fakeGlassProvider` to `true` (the liquid-glass shader does not run headless).
5. For derivation-heavy features, add a dump test that prints the model for every state pictured in the mockup (e.g. `prStatus()` → identity/tone/dot/cta/signals) and run with `--reporter expanded`. Diffing strings beats eyeballing pixels.
6. Open the mockup in the browser (`agent-browser open file://…/mockups/x.html`), then per section `eval` `document.body.style.zoom` + `scrollIntoView({block:'center'})` and `screenshot`. Build a side-by-side comparison HTML in /tmp with `<img>` + a fixed-size `overflow:hidden` wrapper and negative margins to crop, then `agent-browser screenshot --full`.
7. Quantify colour/contrast claims instead of eyeballing: resolve the token in `app/lib/app/theme.dart` and compute the WCAG ratio against the actual surface (e.g. `cs.outlineVariant #333` on `surfaceContainerHigh #2E2E2E` = 1.07:1 → invisible).

## Pitfalls
- A widget test's default font is Ahem — unloaded fonts silently produce black-box text and a useless golden.
- `tester.view.physicalSize` is in physical pixels; forgetting `* dpr` renders at the wrong logical width and fakes truncation.
- `StateProvider.overrideWith` takes the *value* type in riverpod 3 (`(ref) => true`), and legacy providers need `import 'package:flutter_riverpod/legacy.dart'`.
- Seven always-expanded composers do not fit one image — chunk ladders into 4 scenes per golden, or the rows shrink past reading.
- Mockup pictures often lag their own legend (hand-coloured dots, stale section tags). Check the legend and the §8 'as built' table before calling a difference a defect.
- A `Column` of fixed-height children inside `Expanded` overflows when the composer is tall; give the scene enough logical height or the golden fails with a RenderFlex error.
- **Mockup casing is CSS, not data.** The boards use `text-transform:uppercase` (10+ uses in doc-preview.html) while the HTML source is lowercase (`class="status draft">draft`). A screenshot showing `DRAFT` is not evidence the label should be uppercase — grep the source before filing a casing deviation.
- **Check what the spec told the screen to reuse.** SPEC-46 line 115 maps the Docs screen to `app/lib/ui/ports/ports_screen.dart`, so its chrome must be diffed against the *shipped Ports screen*, not the mockup: `←` back arrow, `title · subtitle`, ✓-marked selected chip with plain counts, `UPPERCASE-DIRNAME <count>` group header, branch-icon sub-header, lowercase status pills. Deviations that match Ports are consistency wins; only deviations from BOTH the mockup and the reused screen are defects.
- **Compare like-for-like themes.** The boards are dark; a freshly `simctl erase`d simulator boots light. Run `xcrun simctl ui <id> appearance dark` before capturing, or every colour claim is wrong.
- A control can be present and inert: verify a layout toggle actually reflows by diffing text wrap between before/after screenshots, not by trusting its selected tint (makit's reader-width toggle is 680pt on a 393pt phone, so it can never bind).
## Verification
1. `flutter test --no-pub --update-goldens test/sim/…` passes and the PNGs contain readable glyphs (not black boxes).
2. Every reported deviation cites the implementation file:line and the mockup line number.
3. Every colour claim is backed by a computed contrast ratio against the real surface token.
4. Differences already recorded in the mockup's §8 'where this mock was wrong' table are reported as documented, not as bugs.
