// Regression tests for the composer's send-slot crossfade (the trailing
// [+]/send/stop button), independent of the queue.
//
// The slot is an [AnimatedSwitcher] over three keyed children. Its states are
// mutually exclusive but re-entrant: text → send, cleared → disabled, turn
// starts → cancel, turn ends → disabled again. Any A→B→A inside the 180ms
// crossfade used to hand the switcher's Stack two children with the SAME key,
// which trips Flutter's `Duplicate keys found` assertion (a red screen in
// debug, and an exception that fails any test pumping real frames).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/composer/composer.dart';

/// Pump real frames for [d] — a single fat `pump(d)` advances the animation
/// controller without ever rendering the frame that retires the outgoing child,
/// which is what hid this bug from the existing suite.
Future<void> frames(WidgetTester tester, Duration d) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  var elapsed = Duration.zero;
  while (elapsed < d && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 16));
    elapsed += const Duration(milliseconds: 16);
  }
}

void main() {
  testWidgets('send slot survives disabled → send → disabled inside 180ms', (
    tester,
  ) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(
            controller: ctrl,
            alwaysExpanded: true,
            onSend: (_) {},
          ),
        ),
      ),
    );

    // Each step is well inside the 180ms crossfade.
    await tester.enterText(find.byType(TextField), 'hello');
    await frames(tester, const Duration(milliseconds: 48));
    await tester.tap(find.byKey(const ValueKey('send')));
    await frames(tester, const Duration(milliseconds: 48));
    await tester.enterText(find.byType(TextField), 'again');
    await frames(tester, const Duration(milliseconds: 48));

    expect(tester.takeException(), isNull);
  });

  testWidgets('send slot survives send → cancel → send inside 180ms', (
    tester,
  ) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);
    var running = false;
    late StateSetter setOuter;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return Scaffold(
              body: Composer(
                controller: ctrl,
                alwaysExpanded: true,
                running: running,
                onCancel: () {},
                onSend: (_) {},
              ),
            );
          },
        ),
      ),
    );

    // The real sequence when a turn starts and ends under a typing user.
    await tester.enterText(find.byType(TextField), 'go');
    await frames(tester, const Duration(milliseconds: 32));
    await tester.tap(find.byKey(const ValueKey('send')));
    setOuter(() => running = true);
    await frames(tester, const Duration(milliseconds: 32));
    setOuter(() => running = false);
    await frames(tester, const Duration(milliseconds: 32));
    setOuter(() => running = true);
    await frames(tester, const Duration(milliseconds: 32));

    expect(tester.takeException(), isNull);
  });

  testWidgets('the send button keeps its stable key for callers/tests', (
    tester,
  ) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Composer(
            controller: ctrl,
            alwaysExpanded: true,
            onSend: (_) {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('send-disabled')), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'x');
    await frames(tester, const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('send')), findsOneWidget);
  });
}
