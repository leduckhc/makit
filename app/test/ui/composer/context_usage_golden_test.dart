// Golden "screenshots" of the SPEC-37 context-usage ring + details panel. Run:
//   flutter test --update-goldens test/ui/composer/context_usage_golden_test.dart
// to (re)generate the PNGs under goldens/.
//
// Worth having as a golden rather than only assertions: the ring is a
// CustomPainter whose whole job is legibility at 18px, and the panel's value is
// its layout. Neither is provable by finding text.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/composer/context_usage.dart';

/// Real captures from the verified runs (see SPEC-37 → "Verified against the
/// real binaries"), so the goldens show numbers the app actually receives.
const _codex = SessionUsage(
  contextTokens: 19440,
  contextWindow: 258400,
  totals: SessionUsageTotals(
    total: 19440,
    input: 19435,
    cachedInput: 3840,
    cacheWrite: 0,
    output: 5,
    reasoning: 0,
  ),
  measuredAt: 1,
);

const _pi = SessionUsage(
  contextTokens: 29408,
  contextWindow: 1000000,
  cost: UsageCost(amount: 0.1838725, currency: 'USD'),
  measuredAt: 1,
);

const _tightening = SessionUsage(
  contextTokens: 201000,
  contextWindow: 258400,
  totals: SessionUsageTotals(
    total: 712000,
    input: 698000,
    cachedInput: 631000,
    output: 9400,
    reasoning: 4100,
  ),
  cost: UsageCost(amount: 1.42, currency: 'USD'),
  measuredAt: 1,
);

Widget _scene(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: makitDarkTheme,
  home: Builder(
    builder: (context) => Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Center(
        child: Padding(padding: const EdgeInsets.all(20), child: child),
      ),
    ),
  ),
);

/// A row of bare rings at the footer's real 18px size, so the goldens answer the
/// question the mockup could only assert: is a 3% arc actually visible?
///
/// There is no unmeasured rung: without a known window the control is not
/// rendered at all, so no ring exists for that state.
Widget _ringLadder() => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    for (final f in <double>[0.03, 0.08, 0.42, 0.78, 0.94, 1.0])
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: ContextUsageRing(fraction: f),
      ),
  ],
);

void main() {
  // Goldens that contain TEXT are platform-dependent: macOS (where these were
  // generated) rasterizes glyphs differently than the Linux CI runner, which
  // showed up as a 2.3–3.2% pixel diff. Same convention as
  // `test/desktop/chat/open_in_ide_golden_test.dart`; regenerate with:
  //   flutter test --update-goldens test/ui/composer/context_usage_golden_test.dart
  //
  // The ring ladder is deliberately NOT skipped. It is pure geometry with no
  // glyphs, it matched byte-for-byte on the Linux runner, and it is the golden
  // that actually guards the CustomPainter — the thing most likely to regress
  // unnoticed. Blanket-skipping it off macOS would give CI no coverage of the
  // ring at all.
  final skipOffMac = !Platform.isMacOS;

  testWidgets('ring ladder at the real 18px footer size', (tester) async {
    // physicalSize is in PHYSICAL pixels, so it must be scaled by the DPR:
    // 6 rings × (18 + 2×8 padding) + 2×20 scene padding ≈ 245 logical.
    tester.view.physicalSize = const Size(245 * 3, 80 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_scene(_ringLadder()));
    await expectLater(
      find.byType(Row).first,
      matchesGoldenFile('goldens/spec37_ring_ladder.png'),
    );
  });

  for (final (name, usage) in <(String, SessionUsage)>[
    ('codex', _codex),
    ('pi', _pi),
    ('tightening', _tightening),
  ]) {
    testWidgets('details panel — $name', (tester) async {
      // Logical 340×620 (panel 300 + scene padding), scaled by the DPR.
      tester.view.physicalSize = const Size(340 * 3, 620 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _scene(
          SizedBox(
            width: kUsagePanelWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF333333)),
                borderRadius: BorderRadius.circular(14),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ContextUsageDetails(usage: usage),
              ),
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(ContextUsageDetails),
        matchesGoldenFile('goldens/spec37_panel_$name.png'),
      );
    }, skip: skipOffMac);
  }
}
