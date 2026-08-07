// A low-cadence replacement for Material's indeterminate spinner, used where a
// spinner can stay on screen while real work happens.
//
// Measured: one indeterminate CircularProgressIndicator is one vsync ticker, so
// a single long-lived spinner puts the app back at ~120 fps and cancels the
// PulseClock saving (121 -> 20 fps, raster 166 -> 29ms per 3s window) for as
// long as it is visible. The transcript's per-tool-call spinner is on screen for
// most of every turn, which is exactly the state the user profiled at ~30% CPU.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/widgets/pulse.dart';
import 'package:makit/ui/widgets/pulse_spinner.dart';

void main() {
  Future<void> pumpSpinner(WidgetTester tester, {Color? color}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PulseSpinner(color: color)),
        ),
      );

  testWidgets('spins on the shared clock, not at vsync', (tester) async {
    await pumpSpinner(tester);
    await tester.pump();

    expect(find.byType(PulseBuilder), findsOneWidget);
    // The whole point: no ticker holding a frame permanently requested.
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('is not a Material progress indicator', (tester) async {
    await pumpSpinner(tester);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('sizes to its dimension and settles (no pending ticker)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PulseSpinner(size: 10))),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(PulseSpinner)), const Size(10, 10));
  });

  testWidgets('carries the loading-spinner role Material would have', (
    tester,
  ) async {
    // Material's CircularProgressIndicator always emits a Semantics node with
    // SemanticsRole.loadingSpinner, so replacing it must not drop that: at the
    // tool-call and upload sites the spinner IS the only signal that something
    // is in flight.
    final handle = tester.ensureSemantics();
    await pumpSpinner(tester);
    await tester.pump();

    expect(
      tester.getSemantics(find.byType(PulseSpinner)).role,
      SemanticsRole.loadingSpinner,
    );
    handle.dispose();
  });

  testWidgets('an optional label names what is in flight', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PulseSpinner(semanticsLabel: 'running')),
      ),
    );
    await tester.pump();

    expect(
      tester.getSemantics(find.byType(PulseSpinner)).label,
      contains('running'),
    );
    handle.dispose();
  });

  test('the arc advances with elapsed time and wraps at one revolution', () {
    // A full turn per period, wrapping rather than jumping backwards.
    expect(spinnerTurns(Duration.zero), 0);
    expect(
      spinnerTurns(const Duration(milliseconds: 500)),
      closeTo(0.5, 0.001),
    );
    expect(spinnerTurns(const Duration(milliseconds: 1000)), closeTo(0, 0.001));
    expect(
      spinnerTurns(const Duration(milliseconds: 1500)),
      closeTo(0.5, 0.001),
    );
  });

  testWidgets('repaints only when the arc actually moved', (tester) async {
    // The clock ticks for every indicator in the app; a spinner whose angle did
    // not change must not add raster work on that tick.
    const a = SpinnerPainter(turns: 0.25, color: Colors.white, strokeWidth: 2);
    const same = SpinnerPainter(
      turns: 0.25,
      color: Colors.white,
      strokeWidth: 2,
    );
    const moved = SpinnerPainter(
      turns: 0.3,
      color: Colors.white,
      strokeWidth: 2,
    );

    expect(a.shouldRepaint(same), isFalse);
    expect(a.shouldRepaint(moved), isTrue);
  });
}
