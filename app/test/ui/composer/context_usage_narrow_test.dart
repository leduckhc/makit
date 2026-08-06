import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/context_usage.dart';

/// The context-usage panel must open usably from a ring sitting at the right
/// edge of a NARROW pane (SPEC-37 follow-up).
///
/// Two independent failures were measured before this existed, both with the
/// ring hard against the right edge:
///  - desktop at 280pt: the popover is a fixed 300pt and `MenuAnchor` clamps its
///    POSITION but not its SIZE, so 36px of the panel hung off the window;
///  - mobile at 320pt: the sheet's content is a plain `Column`, so the narrower
///    rows wrapped, the content grew past the sheet's max height and it threw
///    `RenderFlex overflowed by 37 pixels on the bottom`.
///
/// The real session that exposed this — 33.7M billed, $22.16 — is used as the
/// fixture, because its long numbers are what make the rows wrap.
const _usage = SessionUsage(
  contextTokens: 288000,
  contextWindow: 1000000,
  totals: SessionUsageTotals(
    total: 33700000,
    input: 33500000,
    cachedInput: 33300000,
    cacheWrite: 271000,
    output: 153000,
    reasoning: 4100,
  ),
  cost: UsageCost(amount: 22.16, currency: 'USD'),
  measuredAt: 1,
);

void main() {
  /// Pumps the button hard against the right edge of a [width]×[height] window
  /// and opens it, exactly as a user would from a narrow pane's composer footer.
  Future<void> openPanel(
    WidgetTester tester, {
    required double width,
    required double height,
    required bool desktop,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final c = ProviderContainer(
      overrides: [sessionUsageProvider('s1').overrideWithValue(_usage)],
    );
    addTearDown(c.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                Row(
                  children: [
                    const Spacer(),
                    ContextUsageButton(sessionId: 's1', desktop: desktop),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ContextUsageRing));
    await tester.pumpAndSettle();
  }

  /// The panel's VIEWPORT — the box the user actually sees.
  ///
  /// Not `ContextUsageDetails`: that is the scrolling *content*, whose rect
  /// legitimately extends past the viewport when it is taller than the cap. An
  /// earlier draft of this test measured it and "failed" on a correct layout.
  Rect viewport(WidgetTester tester) => tester.getRect(
    find
        .ancestor(
          of: find.byType(ContextUsageDetails),
          matching: find.byType(SingleChildScrollView),
        )
        .first,
  );

  group('desktop popover in a narrow window', () {
    for (final width in [700.0, 360.0, 280.0, 240.0]) {
      testWidgets('${width.toInt()}pt keeps the whole panel on screen', (
        tester,
      ) async {
        await openPanel(tester, width: width, height: 700, desktop: true);

        expect(tester.takeException(), isNull);
        final panel = viewport(tester);
        expect(panel.left, greaterThanOrEqualTo(0));
        expect(
          panel.right,
          lessThanOrEqualTo(width),
          reason:
              'the panel must not hang off the right edge at ${width.toInt()}pt',
        );
        // Still worth opening: readable, not a sliver.
        expect(panel.width, greaterThan(200));
        expect(find.textContaining('288k of 1.0M'), findsOneWidget);
      });
    }

    testWidgets('a short window keeps the panel on screen too', (tester) async {
      // The popover opens downward from a footer control, so a short window is
      // the vertical equivalent of the narrow case.
      await openPanel(tester, width: 700, height: 360, desktop: true);

      expect(tester.takeException(), isNull);
      final panel = viewport(tester);
      expect(panel.top, greaterThanOrEqualTo(0));
      expect(panel.bottom, lessThanOrEqualTo(360));
      // And the content is reachable rather than clipped away: the panel scrolls.
      expect(
        tester.getRect(find.byType(ContextUsageDetails)).height,
        greaterThan(panel.height),
        reason: 'a short window should cap the panel and scroll inside it',
      );
    });
  });

  group('mobile sheet on a narrow phone', () {
    for (final width in [393.0, 320.0]) {
      testWidgets('${width.toInt()}pt opens without overflowing', (
        tester,
      ) async {
        await openPanel(tester, width: width, height: 700, desktop: false);

        expect(
          tester.takeException(),
          isNull,
          reason: 'the sheet content must scroll rather than overflow',
        );
        expect(find.textContaining('288k of 1.0M'), findsOneWidget);
      });
    }

    testWidgets('a short window still shows the numbers, scrolled', (
      tester,
    ) async {
      // A landscape phone leaves the sheet very little height; the content has
      // to scroll rather than clip, or the cost line is simply unreachable.
      await openPanel(tester, width: 568, height: 320, desktop: false);

      expect(tester.takeException(), isNull);
      expect(find.byType(ContextUsageDetails), findsOneWidget);
    });
  });
}
