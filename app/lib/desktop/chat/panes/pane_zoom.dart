/// Per-pane zoom arithmetic (SPEC-pane-zoom D3, D4, D5).
///
/// Pure Dart on purpose: the ladder and the clamp are the parts most likely to
/// be wrong, so they unit-test without a widget tree.
///
/// Zoom is a *text* scale, not a geometric one (D1). The pane reflows to its
/// real width, so a wide code block never clips.
abstract final class PaneZoom {
  /// The neutral factor. A pane at [none] is not zoomed, and shows no chip.
  static const double none = 1;

  /// The ladder the keyboard steps (D4).
  ///
  /// Browser-style stops, so repeated presses land on the same values every
  /// time. Denser near [none], where users spend their time, and [none] is an
  /// exact member so `⌘0` is also reachable by stepping.
  static const List<double> stops = [
    0.6,
    0.67,
    0.75,
    0.8,
    0.9,
    none,
    1.1,
    1.25,
    1.4,
    1.6,
    1.8,
    2,
    2.2,
    2.4,
  ];

  /// The smallest scale. Below this the composer's controls stop being usable.
  static double get min => stops.first;

  /// The largest scale. Above this a half-width pane wraps tool rows badly,
  /// even on a 4K display.
  static double get max => stops.last;

  /// The next stop above [zoom]. Holds at [max].
  ///
  /// [zoom] need not be a stop: a pinch leaves a continuous value behind (D5),
  /// and stepping from 1.03 must land on 1.1, not on 1.0.
  static double stepIn(double zoom) {
    final from = clamp(zoom);
    for (final stop in stops) {
      if (stop > from + _epsilon) return stop;
    }
    return max;
  }

  /// The next stop below [zoom]. Holds at [min]. See [stepIn] for why [zoom]
  /// may sit between two stops.
  static double stepOut(double zoom) {
    final from = clamp(zoom);
    for (final stop in stops.reversed) {
      if (stop < from - _epsilon) return stop;
    }
    return min;
  }

  /// Scales [zoom] by [factor] and clamps it, without snapping to a stop.
  ///
  /// This is the pinch and modifier+wheel path (D5). A pinch that snapped to 14
  /// stops would feel notchy.
  static double nudge(double zoom, double factor) => clamp(zoom * factor);

  /// Confines [zoom] to [min]–[max].
  static double clamp(double zoom) => zoom.clamp(min, max);

  /// The scale to hand to a `TextScaler` for a pane (D3).
  ///
  /// The global preference keeps its meaning, so a zoomed pane still follows it.
  /// The clamp applies to the *product*: 1.3 × 2.4 must not reach 3.1.
  static double effective({
    required double globalTextScale,
    required double zoom,
  }) => clamp(globalTextScale * zoom);

  /// [zoom] as a whole percent, for the pane chip (D10).
  static String label(double zoom) => '${(zoom * 100).round()}%';

  /// Absorbs the floating-point error in stops such as 0.67, so a comparison
  /// against a stored value does not step twice or not at all.
  static const double _epsilon = 1e-9;
}
