/// Hand-painted metrics charts (SPEC-37 decision 8).
///
/// Three shapes do not justify a chart dependency, and `fl_chart` would bring
/// animation controllers we would immediately have to fight — SPEC-32's
/// sparkline set the precedent.
///
/// Every painter here places points on the **time** axis (`ts`), never on the
/// sample index. The ring deliberately mixes cadences (5 s in the background,
/// 1 Hz while watched), so an index-based x-axis would silently stretch the
/// coarse span to look like a fine one and put the cadence seam in the wrong
/// place — the chart would misreport *when* cost happened.
library;

import 'package:flutter/widgets.dart';

/// One plotted point: an epoch-ms timestamp and a value that may be absent.
///
/// [value] is nullable because `cpuPercent` is null until a rate is computable
/// (decision 2). A null is a **gap**, not a zero: coercing it would draw a dive
/// to the floor that never happened.
typedef MetricPoint = ({int ts, double? value});

/// Normalised x for [ts] within `[t0, t1]`, in `[0, width]`. A zero-width time
/// span (one sample, or several sharing a timestamp) collapses to the left edge
/// rather than dividing by zero.
double metricX(int ts, int t0, int t1, double width) {
  final span = t1 - t0;
  if (span <= 0) return 0;
  return width * ((ts - t0) / span);
}

/// Builds a polyline for [points] scaled to [size], with [maxY] as the top of
/// the axis. Null values break the line into separate segments, so a gap reads
/// as a gap.
///
/// Returns an empty path when there is nothing plottable, which every caller
/// must be able to paint without special-casing.
Path buildMetricPath(List<MetricPoint> points, Size size, double maxY) {
  final path = Path();
  if (points.isEmpty) return path;
  final t0 = points.first.ts;
  final t1 = points.last.ts;
  final span = maxY <= 0 ? 1.0 : maxY;
  var penDown = false;
  for (final p in points) {
    final v = p.value;
    if (v == null) {
      // End the current segment; the next non-null starts a new one.
      penDown = false;
      continue;
    }
    final x = metricX(p.ts, t0, t1, size.width);
    final y = size.height - (v / span).clamp(0.0, 1.0) * size.height;
    if (penDown) {
      path.lineTo(x, y);
    } else {
      path.moveTo(x, y);
      penDown = true;
    }
  }
  return path;
}

/// The largest value in [points], or null when every point is a gap. Callers use
/// it to scale an axis; a null means "nothing to draw", not "zero".
double? metricPeak(List<MetricPoint> points) {
  double? peak;
  for (final p in points) {
    final v = p.value;
    if (v == null) continue;
    if (peak == null || v > peak) peak = v;
  }
  return peak;
}

/// A flat one-series sparkline for a surface row. Scales to its own peak (with
/// [minPeak] as a floor) so a quiet series does not amplify noise into a
/// mountain range.
class MetricSparklinePainter extends CustomPainter {
  /// Creates the painter.
  const MetricSparklinePainter({
    required this.points,
    required this.color,
    this.minPeak = 1.0,
  });

  /// The series, oldest first.
  final List<MetricPoint> points;

  /// Stroke colour.
  final Color color;

  /// Axis floor, so an all-zero series draws along the bottom instead of being
  /// scaled up to fill the box.
  final double minPeak;

  @override
  void paint(Canvas canvas, Size size) {
    final peak = metricPeak(points);
    if (peak == null) return;
    final path = buildMetricPath(points, size, peak < minPeak ? minPeak : peak);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(MetricSparklinePainter old) =>
      old.points != points || old.color != color || old.minPeak != minPeak;
}
