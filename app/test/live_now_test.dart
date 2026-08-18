import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/live_now.dart';

/// A clock a unit test can tick deterministically, standing in for [PulseClock].
class _FakeClock extends ChangeNotifier {
  void tick() => notifyListeners();

  /// Own probe rather than `hasListeners`, which is `@protected` on
  /// ChangeNotifier — reading it from a test is a lint, not a contract.
  int listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listenerCount--;
    super.removeListener(listener);
  }
}

void main() {
  group('ServerNowTicker (SPEC-session-timings D5)', () {
    test('exposes the current server-now on construction', () {
      const now = 42000;
      final ticker = ServerNowTicker(nowMs: () => now, clock: _FakeClock());
      expect(ticker.value, 42000);
      ticker.dispose();
    });

    test('notifies only when the whole second changes', () {
      var now = 1000;
      final clock = _FakeClock();
      final ticker = ServerNowTicker(nowMs: () => now, clock: clock);
      var notifications = 0;
      ticker.addListener(() => notifications++);

      now = 1200; // same second (1s)
      clock.tick();
      expect(notifications, 0);

      now = 2000; // crossed into the next second
      clock.tick();
      expect(notifications, 1);
      expect(ticker.value, 2000);

      ticker.dispose();
    });

    test('reduced-motion cadence only ticks every 5 seconds', () {
      var now = 0;
      final clock = _FakeClock();
      final ticker = ServerNowTicker(
        nowMs: () => now,
        clock: clock,
        cadence: kLiveTickReducedMotionCadence,
      );
      var notifications = 0;
      ticker.addListener(() => notifications++);

      now = 3000; // 3s — inside the first 5s bucket
      clock.tick();
      expect(notifications, 0);

      now = 5000; // crossed the 5s boundary
      clock.tick();
      expect(notifications, 1);

      ticker.dispose();
    });

    test('stops listening to its clock on dispose', () {
      const now = 0;
      final clock = _FakeClock();
      final ticker = ServerNowTicker(nowMs: () => now, clock: clock);
      expect(clock.listenerCount, 1);
      ticker.dispose();
      expect(clock.listenerCount, 0);
    });
  });
}
