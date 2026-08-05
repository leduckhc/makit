import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/metrics/charts.dart';

void main() {
  group('metricX', () {
    test('places a timestamp proportionally along the axis', () {
      expect(metricX(1000, 1000, 3000, 100), 0);
      expect(metricX(2000, 1000, 3000, 100), 50);
      expect(metricX(3000, 1000, 3000, 100), 100);
    });

    /// A single sample, or several sharing a timestamp, gives a zero-width span.
    /// Dividing by it would put every point at NaN and paint nothing at all.
    test('a zero-width time span collapses to the left edge, not NaN', () {
      expect(metricX(1000, 1000, 1000, 100), 0);
      expect(metricX(1000, 3000, 1000, 100), 0);
    });
  });

  group('metricPeak', () {
    test('is null when every point is a gap — "nothing", not "zero"', () {
      expect(metricPeak(const [(ts: 1, value: null)]), isNull);
      expect(metricPeak(const []), isNull);
    });

    test('ignores gaps and returns the largest value', () {
      expect(
        metricPeak(const [
          (ts: 1, value: 2.0),
          (ts: 2, value: null),
          (ts: 3, value: 9.5),
        ]),
        9.5,
      );
    });
  });

  group('buildMetricPath', () {
    const size = Size(100, 50);

    test('an empty series paints an empty path rather than throwing', () {
      expect(
        buildMetricPath(const [], size, 10).computeMetrics().isEmpty,
        isTrue,
      );
    });

    test('a single sample yields a degenerate path, not an exception', () {
      final path = buildMetricPath(const [(ts: 1, value: 5.0)], size, 10);
      // A moveTo with no lineTo has no length but valid (finite) bounds.
      expect(path.getBounds().isFinite, isTrue);
    });

    /// Time-based placement is the whole point: the ring mixes 5 s and 1 Hz
    /// samples, so an index-based x-axis would stretch the coarse span to look
    /// like the fine one and put the cadence seam in the wrong place.
    test('x follows the timestamp, not the sample index', () {
      // Three samples, but the middle one sits 90% of the way through time.
      final path = buildMetricPath(
        const [
          (ts: 0, value: 1.0),
          (ts: 900, value: 1.0),
          (ts: 1000, value: 1.0),
        ],
        size,
        1,
      );
      final bounds = path.getBounds();
      expect(bounds.left, 0);
      expect(bounds.right, 100);
      // A flat series at the axis top sits on y = 0.
      expect(bounds.top, 0);
    });

    test('a value above maxY is clamped into the box', () {
      final path = buildMetricPath(
        const [(ts: 0, value: 999.0), (ts: 10, value: 999.0)],
        size,
        1,
      );
      expect(path.getBounds().top, greaterThanOrEqualTo(0.0));
    });

    test('a zero maxY does not divide by zero', () {
      final path = buildMetricPath(
        const [(ts: 0, value: 0.0), (ts: 10, value: 0.0)],
        size,
        0,
      );
      expect(path.getBounds().isFinite, isTrue);
    });

    /// A null is a gap, not a zero: coercing it would draw a dive to the floor
    /// that never happened. Two segments must therefore be two subpaths.
    test('a gap breaks the line into separate segments', () {
      final continuous = buildMetricPath(
        const [(ts: 0, value: 1.0), (ts: 5, value: 1.0), (ts: 10, value: 1.0)],
        size,
        1,
      );
      final withGap = buildMetricPath(
        const [(ts: 0, value: 1.0), (ts: 5, value: null), (ts: 10, value: 1.0)],
        size,
        1,
      );
      expect(continuous.computeMetrics().length, 1);
      expect(withGap.computeMetrics().length, isNot(1));
    });

    test('a leading gap does not anchor the line at the origin', () {
      final path = buildMetricPath(
        const [(ts: 0, value: null), (ts: 10, value: 1.0)],
        size,
        1,
      );
      // Only the real sample is plotted, at the right-hand edge.
      expect(path.getBounds().left, 100);
    });
  });

  group('MetricSparklinePainter', () {
    /// The three ring sizes the painter must survive: empty, one sample, full.
    test('paints an empty, a single-sample and a many-sample series', () {
      for (final points in <List<MetricPoint>>[
        const [],
        const [(ts: 1, value: 3.0)],
        List<MetricPoint>.generate(
          600,
          (i) => (ts: i * 1000, value: (i % 7).toDouble()),
        ),
      ]) {
        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        MetricSparklinePainter(
          points: points,
          color: const Color(0xFF00FF00),
        ).paint(canvas, const Size(48, 14));
        expect(recorder.endRecording(), isNotNull);
      }
    });

    test('an all-gap series paints nothing rather than a floor line', () {
      const painter = MetricSparklinePainter(
        points: [(ts: 1, value: null)],
        color: Color(0xFF00FF00),
      );
      final recorder = PictureRecorder();
      painter.paint(Canvas(recorder), const Size(48, 14));
      expect(recorder.endRecording(), isNotNull);
    });

    test('repaints only when its inputs change', () {
      const a = MetricSparklinePainter(
        points: [(ts: 1, value: 1.0)],
        color: Color(0xFF00FF00),
      );
      const b = MetricSparklinePainter(
        points: [(ts: 1, value: 1.0)],
        color: Color(0xFFFF0000),
      );
      expect(a.shouldRepaint(a), isFalse);
      expect(a.shouldRepaint(b), isTrue);
    });
  });
}
