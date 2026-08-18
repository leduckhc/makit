import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/context_usage.dart';

/// SPEC-context-usage — the circular context gauge and its details panel.
///
/// Two rules run through all of it: **absent is not zero** (a reading nobody
/// took must render as nothing, never as 0%), and the cumulative session total
/// must never be presented as context occupancy.

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

ProviderContainer _container(SessionUsage? usage) => ProviderContainer(
  overrides: [sessionUsageProvider('s1').overrideWithValue(usage)],
);

Widget _wrap(ProviderContainer c, {bool desktop = false}) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: ContextUsageButton(sessionId: 's1', desktop: desktop),
          ),
        ),
      ),
    );

void main() {
  group('formatTokens', () {
    test('abbreviates thousands and millions', () {
      expect(formatTokens(0), '0');
      expect(formatTokens(999), '999');
      expect(formatTokens(1000), '1.0k');
      expect(formatTokens(19440), '19.4k');
      expect(formatTokens(258400), '258k');
      expect(formatTokens(1000000), '1.0M');
    });

    test('drops the decimal once the mantissa needs three digits', () {
      expect(formatTokens(100000), '100k');
    });
  });

  group('formatCost', () {
    test('uses a symbol for known currencies, the code otherwise', () {
      expect(
        formatCost(const UsageCost(amount: 0.42, currency: 'USD')),
        r'$0.42',
      );
      expect(
        formatCost(const UsageCost(amount: 1.5, currency: 'SEK')),
        'SEK 1.50',
      );
    });

    test('keeps a measured zero — a free model is not an absence', () {
      expect(formatCost(const UsageCost(amount: 0, currency: 'USD')), r'$0.00');
    });
  });

  group('percentLabel', () {
    test('rounds the fraction', () {
      expect(percentLabel(_codex), '8%');
      expect(
        percentLabel(
          const SessionUsage(
            contextTokens: 999,
            contextWindow: 1000,
            measuredAt: 1,
          ),
        ),
        '100%',
      );
    });

    test('is null when either half of the ratio is missing', () {
      expect(
        percentLabel(const SessionUsage(contextTokens: 5, measuredAt: 1)),
        isNull,
      );
      expect(
        percentLabel(const SessionUsage(contextWindow: 5, measuredAt: 1)),
        isNull,
      );
    });
  });

  group('headroomLabel', () {
    test('is what is left before compaction', () {
      expect(headroomLabel(_codex), '239k before compaction');
    });

    test('is null without both numbers', () {
      expect(
        headroomLabel(const SessionUsage(contextTokens: 5, measuredAt: 1)),
        isNull,
      );
    });

    test('never reports negative headroom when the context overshoots', () {
      expect(
        headroomLabel(
          const SessionUsage(
            contextTokens: 300000,
            contextWindow: 258400,
            measuredAt: 1,
          ),
        ),
        '0 before compaction',
      );
    });
  });

  group('cacheShare', () {
    test('is cached input over total input', () {
      expect(cacheShare(_codex.totals!), closeTo(0.1976, 0.0001));
    });

    test('is null when input is unknown or zero', () {
      expect(cacheShare(const SessionUsageTotals(cachedInput: 10)), isNull);
      expect(
        cacheShare(const SessionUsageTotals(input: 0, cachedInput: 0)),
        isNull,
      );
    });
  });

  group('ContextUsageButton — visibility', () {
    testWidgets('renders nothing before the agent reports usage', (
      tester,
    ) async {
      final c = _container(null);
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      expect(find.byType(ContextUsageRing), findsNothing);
    });

    testWidgets('renders nothing for a snapshot carrying no readings', (
      tester,
    ) async {
      final c = _container(const SessionUsage(measuredAt: 1));
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      expect(find.byType(ContextUsageRing), findsNothing);
    });

    testWidgets('shows the ring once there is a context reading', (
      tester,
    ) async {
      final c = _container(_codex);
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      final ring = tester.widget<ContextUsageRing>(
        find.byType(ContextUsageRing),
      );
      expect(ring.fraction, closeTo(0.0752, 0.0001));
    });

    testWidgets('renders nothing when only cost was measured', (tester) async {
      // A ring means "this share of a whole". With no window there is no whole,
      // so there is nothing to draw — not an empty ring.
      final c = _container(
        const SessionUsage(
          cost: UsageCost(amount: 1.25, currency: 'USD'),
          measuredAt: 1,
        ),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      expect(find.byType(ContextUsageRing), findsNothing);
    });

    testWidgets('renders nothing when the window is unreported', (
      tester,
    ) async {
      // An ACP agent may send `used` with no `size`; no percentage exists.
      final c = _container(
        const SessionUsage(contextTokens: 19440, measuredAt: 1),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      expect(find.byType(ContextUsageRing), findsNothing);
    });

    testWidgets('renders nothing while pi is post-compaction', (tester) async {
      // pi keeps reporting the window but nulls the token count until the next
      // assistant response lands. A 0% ring would misread as "context emptied".
      final c = _container(
        const SessionUsage(contextWindow: 200000, measuredAt: 1),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      expect(find.byType(ContextUsageRing), findsNothing);
    });
  });

  group('ContextUsageButton — tap target', () {
    testWidgets('is a thumb target, not the bare 18px ring', (tester) async {
      // The ring is 18px; hit areas are not. This matches the send button's
      // deliberately compact 36px footprint in the same footer row, so the two
      // bare icon controls agree. (Not kTouchRow/44 — that is the list-row scale,
      // and the composer tuned these controls down on purpose.)
      final c = _container(_codex);
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));

      final target = tester.getSize(
        find.ancestor(
          of: find.byType(ContextUsageRing),
          matching: find.byType(InkWell),
        ),
      );
      expect(target.width, kUsageTargetSize);
      expect(target.height, kUsageTargetSize);
      expect(kUsageTargetSize, greaterThanOrEqualTo(36.0));
    });
  });

  group('ContextUsageButton — opening the details', () {
    testWidgets('the numbers are NOT in the footer, only behind the tap', (
      tester,
    ) async {
      final c = _container(_codex);
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      expect(find.textContaining('19.4k'), findsNothing);
      expect(find.text('8%'), findsNothing);
    });

    testWidgets('tapping opens the panel with the context reading', (
      tester,
    ) async {
      final c = _container(_codex);
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));

      await tester.tap(find.byType(ContextUsageRing));
      await tester.pumpAndSettle();

      expect(find.text('8%'), findsOneWidget);
      expect(find.text('19.4k of 258k tokens'), findsOneWidget);
      expect(find.text('239k before compaction'), findsOneWidget);
    });

    testWidgets('the panel separates cumulative totals from context', (
      tester,
    ) async {
      final c = _container(_codex);
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      await tester.tap(find.byType(ContextUsageRing));
      await tester.pumpAndSettle();

      expect(find.text('Session total'), findsOneWidget);
      // The distinction has to be stated: both numbers now sit in one panel.
      expect(find.textContaining('billed across all turns'), findsOneWidget);
    });

    testWidgets('the panel shows the cache share when codex reports it', (
      tester,
    ) async {
      final c = _container(_codex);
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      await tester.tap(find.byType(ContextUsageRing));
      await tester.pumpAndSettle();

      expect(find.textContaining('from cache'), findsOneWidget);
      expect(find.textContaining('20%'), findsOneWidget);
    });

    testWidgets('the panel omits cost entirely when the agent prices nothing', (
      tester,
    ) async {
      final c = _container(_codex);
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      await tester.tap(find.byType(ContextUsageRing));
      await tester.pumpAndSettle();

      expect(find.text('Cost'), findsNothing);
    });

    testWidgets('an ACP-shaped snapshot shows cost and no token breakdown', (
      tester,
    ) async {
      final c = _container(
        const SessionUsage(
          contextTokens: 29408,
          contextWindow: 1000000,
          cost: UsageCost(amount: 0.1838725, currency: 'USD'),
          measuredAt: 1,
        ),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c));
      await tester.tap(find.byType(ContextUsageRing));
      await tester.pumpAndSettle();

      expect(find.text('3%'), findsOneWidget);
      expect(find.text('29.4k of 1.0M tokens'), findsOneWidget);
      expect(find.text(r'$0.18'), findsOneWidget);
      expect(find.text('Session total'), findsNothing);
    });

    testWidgets('the desktop popover survives the window shrinking under it', (
      tester,
    ) async {
      // Found while fixing the same bug in SPEC-session-identity's identity panel, which copied
      // this sizing: `window.width - 2 * margin` goes NEGATIVE below 16pt (2 * _kUsagePanelMargin), and a
      // SizedBox with a negative width is a non-normalized constraint -- the
      // layout ASSERTS instead of rendering a cramped panel. The height axis was
      // already safe (floored by _kUsagePanelMinHeight); the width axis was not.
      //
      // Shrunk WHILE open, because that is both the realistic path (a resize
      // animation or an embedded host hands us one degenerate frame) and the only
      // one that works: at 10x10 the ring is unhittable, so the tap lands on
      // nothing and the test would assert nothing.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = _container(_codex);
      addTearDown(c.dispose);
      await tester.pumpWidget(_wrap(c, desktop: true));
      await tester.tap(find.byType(ContextUsageRing));
      await tester.pumpAndSettle();
      expect(find.byType(ContextUsageDetails), findsOneWidget);
      tester.view.physicalSize = const Size(10, 10);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
