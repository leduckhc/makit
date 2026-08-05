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

/// One named series for a stacked or multi-line chart.
typedef MetricSeries = ({String label, Color color, List<MetricPoint> points});

/// Stacked bands, one per series, sharing a time axis (Tier 2 CPU + memory
/// cells).
///
/// Bands are summed **at matching timestamps**, not by index: the series come
/// from the same ring so their `ts` values line up, and pairing by index would
/// silently shift a band by one sample whenever a series had a gap.
class StackedAreaPainter extends CustomPainter {
  /// Creates the painter.
  const StackedAreaPainter({
    required this.series,
    required this.maxY,
    this.gridColor,
    this.gridAtY,
  });

  /// Bottom-to-top band order.
  final List<MetricSeries> series;

  /// Axis ceiling. When null the painter scales to the stacked peak.
  final double? maxY;

  /// Optional reference line (e.g. 100% = one full core).
  final Color? gridColor;

  /// Value at which to draw [gridColor].
  final double? gridAtY;

  /// Every timestamp present in any series, ascending — the shared x-axis.
  List<int> get _timeline {
    final all = <int>{};
    for (final s in series) {
      for (final p in s.points) {
        all.add(p.ts);
      }
    }
    return all.toList()..sort();
  }

  /// Stack ceiling across the whole window, or null when nothing is plottable.
  double? stackedPeak() {
    double? peak;
    for (final ts in _timeline) {
      var sum = 0.0;
      var any = false;
      for (final s in series) {
        final v = _valueAt(s.points, ts);
        if (v == null) continue;
        sum += v;
        any = true;
      }
      if (!any) continue;
      if (peak == null || sum > peak) peak = sum;
    }
    return peak;
  }

  static double? _valueAt(List<MetricPoint> points, int ts) {
    for (final p in points) {
      if (p.ts == ts) return p.value;
    }
    return null;
  }

  /// One filled polygon per contiguous run of measured points, per series,
  /// bottom band first. Exposed so tests can assert the real geometry instead of
  /// merely proving `paint` did not throw.
  ///
  /// A gap **splits** the band. Skipping the null and carrying the polygon across
  /// it drew a filled region over a period that was never measured, which reads
  /// as interpolated data — the same fabrication decisions 2 and 16 forbid for a
  /// single number.
  List<Path> bandPaths(Size size) {
    final out = <Path>[];
    final timeline = _timeline;
    if (timeline.isEmpty) return out;
    final peak = maxY ?? stackedPeak();
    if (peak == null || peak <= 0) return out;
    final t0 = timeline.first;
    final t1 = timeline.last;

    // Running baseline per timestamp, so each band starts where the last ended.
    final baseline = <int, double>{for (final ts in timeline) ts: 0};

    for (final s in series) {
      // Accumulate a run, flushing it whenever a gap interrupts the series.
      var top = <Offset>[];
      var bottom = <Offset>[];

      void flush() {
        // A single point has no area; a degenerate polygon would paint nothing
        // anyway, so it is dropped rather than emitted as an invisible path.
        if (top.length < 2) {
          top = <Offset>[];
          bottom = <Offset>[];
          return;
        }
        final path = Path()..moveTo(bottom.first.dx, bottom.first.dy);
        for (final o in top) {
          path.lineTo(o.dx, o.dy);
        }
        for (final o in bottom.reversed) {
          path.lineTo(o.dx, o.dy);
        }
        path.close();
        out.add(path);
        top = <Offset>[];
        bottom = <Offset>[];
      }

      for (final ts in timeline) {
        final v = _valueAt(s.points, ts);
        if (v == null) {
          flush();
          continue;
        }
        final base = baseline[ts]!;
        final x = metricX(ts, t0, t1, size.width);
        bottom.add(Offset(x, _y(base, peak, size.height)));
        top.add(Offset(x, _y(base + v, peak, size.height)));
        baseline[ts] = base + v;
      }
      flush();
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paths = bandPaths(size);
    // Bands are emitted series-major, so recover each band's colour by walking
    // the same order: one entry per contiguous run within each series.
    var i = 0;
    for (final s in series) {
      final runs = _runCount(s.points, size);
      for (var r = 0; r < runs && i < paths.length; r++, i++) {
        canvas.drawPath(
          paths[i],
          Paint()..color = s.color.withValues(alpha: 0.75),
        );
      }
    }

    final peak = maxY ?? stackedPeak();
    final grid = gridColor;
    final at = gridAtY;
    if (peak != null && peak > 0 && grid != null && at != null && at <= peak) {
      final y = _y(at, peak, size.height);
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = grid
          ..strokeWidth = 1,
      );
    }
  }

  /// Number of paintable runs [points] contributes, matching [bandPaths]'s
  /// flush rule (runs shorter than two points have no area).
  int _runCount(List<MetricPoint> points, Size size) {
    var runs = 0;
    var len = 0;
    for (final ts in _timeline) {
      if (_valueAt(points, ts) == null) {
        if (len >= 2) runs++;
        len = 0;
      } else {
        len++;
      }
    }
    if (len >= 2) runs++;
    return runs;
  }

  static double _y(double v, double peak, double height) =>
      height - (v / peak).clamp(0.0, 1.0) * height;

  @override
  bool shouldRepaint(StackedAreaPainter old) =>
      old.series != series ||
      old.maxY != maxY ||
      old.gridColor != gridColor ||
      old.gridAtY != gridAtY;
}

/// Independent lines on one time axis (server responsiveness cell). Each series
/// is scaled to the shared peak so the lines stay comparable.
class MultiLinePainter extends CustomPainter {
  /// Creates the painter.
  const MultiLinePainter({required this.series, this.minPeak = 1.0});

  /// The lines to draw.
  final List<MetricSeries> series;

  /// Axis floor, so an all-zero chart draws along the bottom.
  final double minPeak;

  @override
  void paint(Canvas canvas, Size size) {
    double? peak;
    for (final s in series) {
      final p = metricPeak(s.points);
      if (p == null) continue;
      if (peak == null || p > peak) peak = p;
    }
    if (peak == null) return;
    final scale = peak < minPeak ? minPeak : peak;
    for (final s in series) {
      canvas.drawPath(
        buildMetricPath(s.points, size, scale),
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(MultiLinePainter old) =>
      old.series != series || old.minPeak != minPeak;
}

/// Frame-time distribution with a budget marker (Tier 2 frame-time cell).
///
/// Bars are counts per bucket, so this painter takes buckets rather than
/// [MetricPoint]s — a histogram has no time axis, which is exactly why it is the
/// honest way to show frame times: "how often was it slow", not "when".
class HistogramPainter extends CustomPainter {
  /// Creates the painter.
  const HistogramPainter({
    required this.buckets,
    required this.color,
    required this.overBudgetColor,
    required this.budgetBucket,
  });

  /// Counts per bucket, left to right.
  final List<int> buckets;

  /// Bar colour under budget.
  final Color color;

  /// Bar colour at or past [budgetBucket].
  final Color overBudgetColor;

  /// Index at which bars start counting as over the frame budget.
  final int budgetBucket;

  /// The bars this painter will draw, each tagged with whether it is over
  /// budget. Exposed so a test can assert real geometry and colour banding
  /// rather than only that `paint` did not throw.
  List<({Rect rect, bool overBudget})> barRects(Size size) {
    final out = <({Rect rect, bool overBudget})>[];
    if (buckets.isEmpty) return out;
    var peak = 0;
    for (final c in buckets) {
      if (c > peak) peak = c;
    }
    if (peak <= 0) return out;
    final slot = size.width / buckets.length;
    const gap = 1.0;
    for (var i = 0; i < buckets.length; i++) {
      final h = (buckets[i] / peak) * size.height;
      if (h <= 0) continue;
      out.add((
        rect: Rect.fromLTWH(
          i * slot,
          size.height - h,
          (slot - gap).clamp(1, slot),
          h,
        ),
        overBudget: i >= budgetBucket,
      ));
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final bar in barRects(size)) {
      canvas.drawRect(
        bar.rect,
        Paint()..color = bar.overBudget ? overBudgetColor : color,
      );
    }
  }

  @override
  bool shouldRepaint(HistogramPainter old) =>
      old.buckets != buckets ||
      old.color != color ||
      old.overBudgetColor != overBudgetColor ||
      old.budgetBucket != budgetBucket;
}
