import 'dart:async';

import 'package:flutter/widgets.dart';

/// The pulse tick interval — 20 Hz.
///
/// A 900 ms fade sampled every 50 ms is still visually smooth, but it produces
/// ~20 frames/s instead of the 120 the display would happily ask for. Profiling
/// the desktop app found five repeating [AnimationController]s (status dots,
/// board live dots, the transcript shimmer, the metrics icon, the brand mark)
/// pinning the compositor at 120 fps and re-collecting the text glyph atlas
/// every frame — ~30% of a core spent pulsing a few 6-px dots.
const Duration kPulseInterval = Duration(milliseconds: 50);

/// A shared low-rate clock for "something is live" indicators.
///
/// One timer for the whole app: every indicator reads the same [elapsed], so N
/// dots coalesce into one rebuild per tick instead of N unsynchronised tickers
/// each demanding their own frame. The timer only runs while something is
/// listening, so a parked app carries no periodic work.
class PulseClock extends ChangeNotifier {
  /// The app-wide clock. Tests construct their own instance instead.
  static final PulseClock instance = PulseClock();

  Timer? _timer;
  Duration _elapsed = Duration.zero;

  /// Time accumulated while the clock had listeners. Indicators derive their
  /// own phase from it, so periods need not agree.
  Duration get elapsed => _elapsed;

  /// Whether the periodic timer is currently running.
  bool get isTicking => _timer != null;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(kPulseInterval, _tick);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _stop();
  }

  void _tick(Timer _) {
    _elapsed += kPulseInterval;
    notifyListeners();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }
}

/// The pulse phase at [elapsed] for a cycle of [period], in 0..1.
///
/// [reverse] gives a triangle wave (fade out and back, like
/// `AnimationController.repeat(reverse: true)`); otherwise a sawtooth that
/// wraps at the period (a sweep).
double pulseValue(Duration elapsed, Duration period, {bool reverse = false}) {
  final periodMs = period.inMilliseconds;
  if (periodMs <= 0) return 0;
  if (!reverse) return (elapsed.inMilliseconds % periodMs) / periodMs;
  final t = (elapsed.inMilliseconds % (periodMs * 2)) / periodMs;
  return t <= 1 ? t : 2 - t;
}

/// Rebuilds [builder] on the shared [PulseClock], inside a [RepaintBoundary].
///
/// Measured A/B on macOS/Impeller (profile build, 12 pulsing dots beside labels
/// plus a 40-line text wall, medians of ~19 interleaved 3s windows):
///
/// * Cadence is what fixes the raster cost. 121 fps → 20 fps took raster from
///   166ms to 29ms per 3s window and UI-thread work from 49ms to 13ms. A
///   `RepaintBoundary` does **not** reduce raster on Impeller (166 → 171ms with
///   the ticker, 50 → 50ms with this clock) — the frame is re-rendered either
///   way, so the only way to pay less is to produce fewer frames.
/// * The boundary earns its keep on the **UI thread**, and only where nothing
///   above it already is one: in a plain `Column` it cut build+paint 155 → 104ms
///   (ticker) and 37 → 23ms (this clock). Inside a `ListView` it measured
///   neutral, because `ListView` already wraps every child in a boundary.
///
/// It is kept here because makit renders these indicators both inside lists
/// (sidebar tiles, transcript — neutral) and outside them (pane headers, the
/// board tab strip, the title-bar metrics glyph — where it pays).
class PulseBuilder extends StatelessWidget {
  /// Creates a pulsing subtree driven at [kPulseInterval].
  const PulseBuilder({
    super.key,
    required this.builder,
    this.period = const Duration(milliseconds: 900),
    this.reverse = true,
    PulseClock? clock,
  }) : _clock = clock;

  /// Builds the pulsing subtree from the current phase (0..1).
  final Widget Function(BuildContext context, double t) builder;

  /// One cycle of the pulse.
  final Duration period;

  /// Whether the phase reverses (triangle) rather than wrapping (sawtooth).
  final bool reverse;

  final PulseClock? _clock;

  @override
  Widget build(BuildContext context) {
    final clock = _clock ?? PulseClock.instance;
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: clock,
        builder: (context, _) => builder(
          context,
          pulseValue(clock.elapsed, period, reverse: reverse),
        ),
      ),
    );
  }
}
