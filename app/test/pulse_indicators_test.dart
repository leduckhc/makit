// Performance invariant: "something is live" indicators must not drive the
// compositor at the display refresh rate.
//
// Profiling the desktop app found five repeating AnimationControllers pinning a
// 120 Hz ProMotion panel at 120 fps — with LAYOUT/PAINT ~0.00ms but the raster
// thread re-collecting the text glyph atlas every frame. A bench A/B on
// macOS/Impeller (profile build) showed the fix is cadence, not repaint isolation:
// 120 → 20 fps cut raster from ~200ms to ~18ms per 2s window, while adding
// RepaintBoundaries at vsync cadence saved nothing. These tests pin the
// cadence: indicators tick on the shared PulseClock, so no frame is scheduled
// at vsync.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/session/chat_transcript.dart' show WorkingIndicator;
import 'package:makit/ui/widgets/pulse.dart';
import 'package:makit/ui/widgets/session_status_dot.dart';

void main() {
  group('SessionStatusDot', () {
    testWidgets('a running dot pulses off the shared clock, not at vsync', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SessionStatusDot(status: SessionStatus.running)),
        ),
      );
      await tester.pump();

      expect(find.byType(PulseBuilder), findsOneWidget);
      // A repeating AnimationController keeps a frame permanently requested;
      // the shared 20 Hz timer does not.
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('pulses via colour alpha, so there is no per-frame saveLayer', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SessionStatusDot(status: SessionStatus.running)),
        ),
      );
      await tester.pump();

      // FadeTransition/Opacity allocate an offscreen layer every frame; fading
      // the dot's own colour costs nothing.
      expect(
        find.descendant(
          of: find.byType(SessionStatusDot),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(SessionStatusDot),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
    });

    testWidgets('parked states render a solid dot and never start the clock', (
      tester,
    ) async {
      // A parked session waits on the human and does no work. Motion means
      // work, so a parked dot must stay solid and add no listener to the clock.
      for (final status in [
        SessionStatus.awaitingInput,
        SessionStatus.awaitingApproval,
      ]) {
        final clock = PulseClock();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SessionStatusDot(status: status, clock: clock),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byType(PulseBuilder),
          findsNothing,
          reason: '$status must not pulse',
        );
        expect(
          clock.isTicking,
          isFalse,
          reason: '$status must not start the clock',
        );
        // The dot must never become a colour-only signal.
        expect(find.byType(Tooltip), findsOneWidget);
        expect(find.byType(Semantics), findsWidgets);
      }
    });

    testWidgets('solid states carry no pulse at all', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SessionStatusDot(status: SessionStatus.idle)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PulseBuilder), findsNothing);
    });

    testWidgets('status changing in place starts and stops the pulse', (
      tester,
    ) async {
      // Session tiles reuse this State across status transitions.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SessionStatusDot(status: SessionStatus.idle)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PulseBuilder), findsNothing);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SessionStatusDot(status: SessionStatus.running)),
        ),
      );
      await tester.pump();
      expect(find.byType(PulseBuilder), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SessionStatusDot(status: SessionStatus.exited)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PulseBuilder), findsNothing);
    });
  });

  group('WorkingIndicator', () {
    testWidgets('shimmer sweeps on the shared clock, not at vsync', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: Scaffold(body: WorkingIndicator())),
        ),
      );
      await tester.pump();

      expect(find.byType(PulseBuilder), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
      // The ShaderMask saveLayer stays — it is the shimmer — but it is now paid
      // 20 times a second instead of 121.
      expect(find.byType(ShaderMask), findsOneWidget);
    });
  });
}
