// Idle-cost invariant: a parked or pressured app must shed resources it can
// rebuild. The observer pauses the pulse clock when the window hides, and it
// trims Flutter's image cache on OS memory pressure and on park.
//
// It never clears the live-image set while the window is visible, because that
// would force on-screen images to reload. See [IdleReclaimObserver].
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/perf/idle_reclaim.dart';
import 'package:makit/ui/widgets/pulse.dart';

void main() {
  group('IdleReclaimObserver', () {
    late PulseClock clock;
    late List<bool> trims; // each entry is the clearLive flag of one trim call

    setUp(() {
      clock = PulseClock();
      trims = [];
    });

    IdleReclaimObserver build() => IdleReclaimObserver(
      clock: clock,
      trim: ({required bool clearLive}) => trims.add(clearLive),
    );

    test('trims the cache on memory pressure without touching live images', () {
      final observer = build();
      clock.addListener(() {});
      expect(clock.isTicking, isTrue);

      observer.didHaveMemoryPressure();

      // Pressure can arrive while the window is visible, so on-screen images
      // must survive: clearLive stays false.
      expect(trims, [false]);
      // Pressure alone does not park the pulse.
      expect(clock.isTicking, isTrue);
    });

    test('pauses the clock and trims live images when the window hides', () {
      final observer = build();
      clock.addListener(() {});
      expect(clock.isTicking, isTrue);

      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);

      expect(clock.isTicking, isFalse);
      // Nothing is on screen while hidden, so the live set is safe to drop.
      expect(trims, [true]);
    });

    test('resumes the clock when the window comes back', () {
      final observer = build();
      clock.addListener(() {});
      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(clock.isTicking, isFalse);

      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(clock.isTicking, isTrue);
      // Resume must not trim, so nothing reloads on return.
      expect(trims, [true]);
    });

    test('treats inactive as visible, so a transient overlay keeps the pulse', () {
      final observer = build();
      clock.addListener(() {});

      observer.didChangeAppLifecycleState(AppLifecycleState.inactive);

      expect(clock.isTicking, isTrue);
      expect(trims, isEmpty);
    });
  });
}
