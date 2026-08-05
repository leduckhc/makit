import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/metrics/frame_timings.dart';

/// A [FrameTiming] whose `totalSpan` (vsyncStart → rasterFinish) is [ms].
FrameTiming _frame(double ms) {
  final micros = (ms * 1000).round();
  return FrameTiming(
    vsyncStart: 0,
    buildStart: 0,
    buildFinish: micros ~/ 2,
    rasterStart: micros ~/ 2,
    rasterFinish: micros,
    rasterFinishWallTime: micros,
  );
}

void main() {
  /// Two surfaces own this collector — the Tier 1 popover and the Tier 2
  /// dashboard — and the normal handoff has BOTH open at once for a moment
  /// ("Open dashboard →" opens the panel, then dismisses the popover). An
  /// idempotent register + unconditional remove silently unregistered the
  /// collector out from under the surface that was still watching, so the
  /// dashboard showed frozen frame stats forever. Ownership is therefore
  /// ref-counted, exactly like `MetricsWatchController`.
  group('ref-counted ownership', () {
    test(
      'a second owner does not re-register, and the first release keeps it',
      () {
        final added = <TimingsCallback>[];
        final removed = <TimingsCallback>[];
        final c = FrameTimingsCollector(add: added.add, remove: removed.add);

        c.acquire();
        c.acquire();
        expect(added, hasLength(1), reason: 'one callback for two owners');

        c.release();
        expect(
          removed,
          isEmpty,
          reason: 'one owner remains — must keep counting',
        );
        expect(c.isRegistered, isTrue);

        c.release();
        expect(removed, hasLength(1));
        expect(c.isRegistered, isFalse);
      },
    );

    test('a release with no owners is a no-op, never a spurious remove', () {
      final removed = <TimingsCallback>[];
      final c = FrameTimingsCollector(add: (_) {}, remove: removed.add);
      c.release();
      c.release();
      expect(removed, isEmpty);
      expect(c.ownerCount, 0);
    });

    test('re-acquiring after the last release registers again', () {
      final added = <TimingsCallback>[];
      final c = FrameTimingsCollector(add: added.add, remove: (_) {});
      c.acquire();
      c.release();
      c.acquire();
      expect(added, hasLength(2));
      expect(c.ownerCount, 1);
    });
  });

  /// Counting add/remove is the whole point: a leaked `addTimingsCallback` runs
  /// for the process lifetime, which is a permanent cost in the feature that
  /// claims makit is cheap.
  group('registration lifecycle', () {
    test(
      'register adds exactly one callback; dispose removes that same one',
      () {
        final added = <TimingsCallback>[];
        final removed = <TimingsCallback>[];
        final c = FrameTimingsCollector(add: added.add, remove: removed.add);

        expect(c.isRegistered, isFalse);
        c.acquire();
        expect(added, hasLength(1));
        expect(c.isRegistered, isTrue);

        c.release();
        expect(removed, hasLength(1));
        expect(removed.single, same(added.single));
        expect(c.isRegistered, isFalse);
      },
    );

    test(
      'a second register does not double-register (would double-count frames)',
      () {
        final added = <TimingsCallback>[];
        final c = FrameTimingsCollector(add: added.add, remove: (_) {});
        c.acquire();
        c.acquire();
        expect(added, hasLength(1));
      },
    );

    test(
      'dispose without register, and a double dispose, remove nothing extra',
      () {
        final removed = <TimingsCallback>[];
        final c = FrameTimingsCollector(add: (_) {}, remove: removed.add);

        c.release();
        expect(removed, isEmpty);

        c.acquire();
        c.release();
        c.release();
        expect(removed, hasLength(1));
      },
    );

    test('re-acquire after release registers again', () {
      final added = <TimingsCallback>[];
      final c = FrameTimingsCollector(add: added.add, remove: (_) {});
      c.acquire();
      c.release();
      c.acquire();
      expect(added, hasLength(2));
    });
  });

  group('stats', () {
    /// Feeds [frames] through the registered callback, as the binding would.
    FrameTimingsCollector collectorFed(List<double> frames) {
      TimingsCallback? cb;
      final c = FrameTimingsCollector(add: (f) => cb = f, remove: (_) {})
        ..acquire();
      cb!(frames.map(_frame).toList());
      return c;
    }

    test(
      'before any frame the stats are empty, not a fabricated zero-latency',
      () {
        final c = FrameTimingsCollector(add: (_) {}, remove: (_) {});
        expect(c.stats.sampleCount, 0);
        expect(c.stats, same(FrameStats.empty));
      },
    );

    test('p50 and p95 are nearest-rank over the recorded frames', () {
      // 1..100 ms: nearest-rank p50 = index round(.5*99) = 50 → 51ms;
      // p95 = index round(.95*99) = 94 → 95ms.
      final c = collectorFed(
        List<double>.generate(100, (i) => (i + 1).toDouble()),
      );
      expect(c.stats.sampleCount, 100);
      expect(c.stats.p50Ms, 51);
      expect(c.stats.p95Ms, 95);
    });

    test('dropped counts only frames over the 16.7ms budget', () {
      final c = collectorFed([5, 10, 16, 17, 20, 33]);
      // 17, 20, 33 exceed 1000/60 = 16.66ms; 16 does not.
      expect(c.stats.dropped, 3);
    });

    test('a frame just inside the 60fps budget is not dropped', () {
      // Not `kFrameBudgetMs` itself: 1000/60 is not representable in whole
      // microseconds, so a frame built from it lands a rounding step above the
      // budget and the boundary case would be about float noise, not policy.
      final c = collectorFed([kFrameBudgetMs - 0.1]);
      expect(c.stats.dropped, 0);
    });

    test('the ring is bounded at capacity and drops the oldest frames', () {
      // 600 slow frames, then 600 fast ones: a bounded ring must retain only
      // the fast tail. An unbounded list would still report the slow p95.
      final c = collectorFed([
        ...List<double>.filled(kFrameRingCapacity, 40),
        ...List<double>.filled(kFrameRingCapacity, 4),
      ]);
      expect(c.stats.sampleCount, kFrameRingCapacity);
      expect(c.stats.p95Ms, 4);
      expect(c.stats.dropped, 0);
    });

    test('a partially-filled ring reports only what it has', () {
      final c = collectorFed([8, 8, 8]);
      expect(c.stats.sampleCount, 3);
      expect(c.stats.p50Ms, 8);
    });
  });
}
