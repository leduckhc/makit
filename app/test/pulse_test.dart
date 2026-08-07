import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/widgets/pulse.dart';

/// The pulse clock exists so idle-but-live indicators (status dots, the
/// shimmer, the metrics icon) stop driving the compositor at the display
/// refresh rate. On a 120 Hz ProMotion panel five repeating
/// `AnimationController`s produced ~120 fps of full-window re-raster for a
/// handful of 6-px dots; one shared low-rate clock caps that at ~20 fps *in
/// total*, no matter how many indicators are on screen.
void main() {
  group('PulseClock', () {
    test('ticks ~20x per second, not at the display refresh rate', () {
      fakeAsync((async) {
        final clock = PulseClock();
        var ticks = 0;
        clock.addListener(() => ticks++);

        async.elapse(const Duration(seconds: 1));

        // 1000ms / 50ms = 20. Anything near 60/120 means we are back on vsync.
        expect(ticks, inInclusiveRange(19, 21));
      });
    });

    test('all listeners advance on the same tick (one frame for N dots)', () {
      fakeAsync((async) {
        final clock = PulseClock();
        final seen = <Duration>[];
        clock.addListener(() => seen.add(clock.elapsed));
        clock.addListener(() => seen.add(clock.elapsed));

        async.elapse(const Duration(milliseconds: 100));

        // Two listeners, two ticks, and each pair reads an identical elapsed —
        // so a rebuild of all indicators coalesces into a single frame.
        expect(seen.length, 4);
        expect(seen[0], seen[1]);
        expect(seen[2], seen[3]);
      });
    });

    test('stops ticking once the last listener leaves', () {
      fakeAsync((async) {
        final clock = PulseClock();
        var ticks = 0;
        void listener() => ticks++;
        clock.addListener(listener);
        async.elapse(const Duration(milliseconds: 100));
        final atRemoval = ticks;
        expect(atRemoval, greaterThan(0));

        clock.removeListener(listener);
        async.elapse(const Duration(seconds: 1));

        // No listeners => no timer => an app with nothing running is silent.
        expect(ticks, atRemoval);
        expect(clock.isTicking, isFalse);
      });
    });

    test('restarts cleanly when a listener comes back', () {
      fakeAsync((async) {
        final clock = PulseClock();
        var ticks = 0;
        void listener() => ticks++;
        clock.addListener(listener);
        async.elapse(const Duration(milliseconds: 100));
        clock.removeListener(listener);
        async.elapse(const Duration(milliseconds: 100));

        clock.addListener(listener);
        async.elapse(const Duration(milliseconds: 100));

        expect(clock.isTicking, isTrue);
        expect(ticks, inInclusiveRange(3, 5));
      });
    });
  });

  group('pulseValue', () {
    const period = Duration(milliseconds: 900);

    test('reversing pulse is a triangle wave over 2x the period', () {
      expect(pulseValue(Duration.zero, period, reverse: true), 0);
      expect(
        pulseValue(const Duration(milliseconds: 450), period, reverse: true),
        closeTo(0.5, 0.001),
      );
      expect(
        pulseValue(const Duration(milliseconds: 900), period, reverse: true),
        closeTo(1, 0.001),
      );
      expect(
        pulseValue(const Duration(milliseconds: 1350), period, reverse: true),
        closeTo(0.5, 0.001),
      );
      // Wraps back to the start rather than jumping.
      expect(
        pulseValue(const Duration(milliseconds: 1800), period, reverse: true),
        closeTo(0, 0.001),
      );
    });

    test('non-reversing pulse is a sawtooth over one period', () {
      expect(pulseValue(Duration.zero, period), 0);
      expect(
        pulseValue(const Duration(milliseconds: 450), period),
        closeTo(0.5, 0.001),
      );
      expect(
        pulseValue(const Duration(milliseconds: 900), period),
        closeTo(0, 0.001),
      );
    });
  });

  group('PulseBuilder', () {
    testWidgets('isolates the pulsing leaf from its siblings', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PulseBuilder(
            builder: (context, t) => const SizedBox(width: 8, height: 8),
          ),
        ),
      );

      // Measured: outside a ListView (whose children are already boundaried)
      // this cut UI-thread build+paint by ~35%. It does not reduce Impeller's
      // raster cost — only the cadence does that — so it is not the headline
      // fix, but it is free where it does not pay and worth a third where it
      // does (pane headers, the board tab strip, the title-bar glyph).
      expect(
        find.descendant(
          of: find.byType(PulseBuilder),
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );
    });

    testWidgets('rebuilds on the shared clock, and stops when unmounted', (
      tester,
    ) async {
      final clock = PulseClock();
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PulseBuilder(
            clock: clock,
            builder: (context, t) {
              builds++;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final afterMount = builds;

      await tester.pump(const Duration(milliseconds: 200));
      expect(builds, greaterThan(afterMount));

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(clock.isTicking, isFalse);
    });
  });
}
