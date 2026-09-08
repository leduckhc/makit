import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/ui/composer/context_usage.dart';

import '../e2e_helpers.dart';

/// SPEC-context-usage — full-stack proof that context usage reaches the UI: the real server
/// emits `session.usage` on the same path the codex/ACP adapters use, it crosses
/// a real WSS connection, the ring appears in the composer footer, and tapping it
/// opens the details panel.
///
/// Unit tests cannot show this: they feed the reducer directly and would pass
/// even if the event never left the server.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('context usage ring appears after the first turn and opens', (
    tester,
  ) async {
    await launchMakit(tester);
    await openFirstSession(tester);

    // Nothing measured before the first turn, so there is no ring at all —
    // an empty ring would assert a reading of 0%.
    expect(find.byType(ContextUsageRing), findsNothing);

    await sendComposerText(tester, 'usage please');
    await pumpUntil(tester, find.text('echo: usage please'));

    await pumpUntil(
      tester,
      find.byType(ContextUsageRing),
      reason: 'session.usage never reached the composer footer',
    );

    // The stub's first-turn ramp is 19,000 + 1,200 = 20,200 of 258,400 ≈ 8%.
    await tester.tap(find.byType(ContextUsageRing));
    await tester.pumpAndSettle();
    expect(find.text('8%'), findsOneWidget);
    expect(find.text('20.2k of 258k tokens'), findsOneWidget);
    expect(find.text(r'$0.02'), findsOneWidget);
  });

  testWidgets('/compact lowers the context usage ring end to end', (
    tester,
  ) async {
    await launchMakit(tester);
    await openFirstSession(tester);

    // Build up usage across several turns so compaction produces a visible drop.
    for (var i = 0; i < 4; i++) {
      await sendComposerText(tester, 'turn $i');
      await pumpUntil(tester, find.textContaining('echo: turn $i'));
    }

    await pumpUntil(tester, find.byType(ContextUsageRing));
    await tester.tap(find.byType(ContextUsageRing));
    await tester.pumpAndSettle();
    expect(find.text('9%'), findsOneWidget);

    // Close the panel so the next send is unobstructed, then compact.
    await tester.tap(find.byType(ContextUsageRing));
    await tester.pumpAndSettle();

    await sendComposerText(tester, '/compact keep the plan');

    // The stub simulates compaction by rolling the usage ramp back five turns,
    // so the reading drops back to the single-turn level.
    await pumpUntil(
      tester,
      find.text('8%'),
      reason: '/compact did not lower the context usage reading',
    );
    expect(find.text('8%'), findsOneWidget);
  });
}
