// Interleaved A/B/C/D bench for the pulse-indicator work. Throwaway: not
// referenced by the app.
//
// Methodology fix over the first attempt: all four variants are measured in ONE
// process, cycling every 4s, so machine drift, window placement, thermal state
// and stray user interaction cannot land on a single arm. Each window also
// reports how many pointer/scroll events it saw — any window with pointers > 0
// is contaminated and must be discarded.
//
//   flutter run --profile -d macos -t tool/perf/pulse_bench.dart
//   flutter run --profile -d macos -t tool/perf/pulse_bench.dart \
//       --dart-define=HOST=column      # no implicit ListView RepaintBoundary
//   flutter run --profile -d macos -t tool/perf/pulse_bench.dart \
//       --no-enable-impeller           # Skia, for the raster-cache comparison
//
// Results (macOS 26.5, M-series, Impeller, profile build; medians of ~19
// interleaved 3s windows per cell, windows with pointers > 0 discarded).
//
// Absolute values are load-dependent — a later run on a busier machine read
// 388ms raster for tickerNoRB against 166ms here, with every arm scaled up
// together. Only within-run comparisons mean anything, which is the whole reason
// the arms are interleaved in one process rather than run separately:
//
//   host=list (rows in a ListView — children are already boundaried)
//     tickerNoRB  117 fps   build  49.3ms   raster 166.1ms
//     tickerRB    117 fps   build  52.4ms   raster 170.6ms
//     clockNoRB    20 fps   build  13.4ms   raster  29.5ms
//     clockRB      20 fps   build  11.1ms   raster  28.8ms
//
//   host=column (no enclosing boundary)
//     tickerNoRB  121 fps   build 154.8ms   raster 254.1ms
//     tickerRB    117 fps   build 103.8ms   raster 269.3ms
//     clockNoRB    20 fps   build  36.8ms   raster  49.5ms
//     clockRB      20 fps   build  22.8ms   raster  49.7ms
//
// Reading: cadence is the only lever on Impeller's raster cost (166 → 29ms);
// a RepaintBoundary never moved raster, but cut UI-thread build+paint by ~33%
// where nothing above it was already a boundary, and was neutral inside a
// ListView. Hence PulseBuilder does both: low cadence + a boundary.
//
// Spinner arms (same run, shimmer+spinner placed inside the viewport):
//     clockRB          20 fps   build  26.6ms   raster  52.9ms
//     clock+matSpin   117 fps   build 131.4ms   raster 293.9ms
//     clock+pulseSpin  20 fps   build  28.9ms   raster  56.8ms
//
// i.e. ONE indeterminate CircularProgressIndicator cancels the entire saving
// (5.6x the raster), because it runs its own repeating AnimationController at
// vsync. PulseSpinner keeps the app at 20 fps for ~4ms more per window.
//
// Variants:
//   tickerNoRB  repeating AnimationController at vsync, no explicit boundary
//   tickerRB    same, each pulsing leaf wrapped in a RepaintBoundary
//   clockNoRB   shared 20 Hz PulseClock, no explicit boundary
//   clockRB     shared 20 Hz PulseClock + RepaintBoundary
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:makit/ui/widgets/pulse.dart';
import 'package:makit/ui/widgets/pulse_spinner.dart';

/// `list` puts rows in a ListView (which adds a RepaintBoundary per child by
/// default); `column` removes that implicit boundary.
const _host = String.fromEnvironment('HOST', defaultValue: 'list');
const _dots = 12;

/// (label, drives at vsync, wrapped in a RepaintBoundary, spinner kind)
///
/// The last two arms answer whether one indeterminate Material spinner is enough
/// to undo the clock's saving: everything else is identical and on the clock.
const _variants = <(String, bool, bool, String)>[
  ('tickerNoRB', true, false, 'none'),
  ('tickerRB', true, true, 'none'),
  ('clockNoRB', false, false, 'none'),
  ('clockRB', false, true, 'none'),
  ('clock+matSpin', false, true, 'material'),
  ('clock+pulseSpin', false, true, 'pulse'),
];

/// Time each variant is on screen; the first [_settle] of it is discarded.
const _hold = Duration(seconds: 4);
const _settle = Duration(seconds: 1);

void main() => runApp(const _BenchApp());

class _BenchApp extends StatefulWidget {
  const _BenchApp();

  @override
  State<_BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<_BenchApp> {
  int _v = 0;
  int _round = 0;
  final _frames = <FrameTiming>[];
  int _pointers = 0;
  late DateTime _variantStart;
  Timer? _cycle;

  @override
  void initState() {
    super.initState();
    _variantStart = DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _cycle = Timer.periodic(_hold, (_) => _next());
  }

  @override
  void dispose() {
    _cycle?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    // Discard the settle window so layer/atlas warm-up is not charged to the
    // variant that follows a switch.
    if (DateTime.now().difference(_variantStart) < _settle) return;
    _frames.addAll(timings);
  }

  void _next() {
    final elapsed = DateTime.now().difference(_variantStart) - _settle;
    final n = _frames.length;
    if (n > 0 && elapsed.inMilliseconds > 0) {
      double total(int Function(FrameTiming) f) =>
          _frames.map(f).fold(0, (a, b) => a + b) / 1000;
      final fps = n / elapsed.inMilliseconds * 1000;
      // ignore: avoid_print
      print(
        'BENCH host=$_host round=$_round variant=${_variants[_v].$1} '
        'fps=${fps.toStringAsFixed(1)} frames=$n win=${elapsed.inMilliseconds}ms '
        'build=${total((t) => t.buildDuration.inMicroseconds).toStringAsFixed(1)}ms '
        'raster=${total((t) => t.rasterDuration.inMicroseconds).toStringAsFixed(1)}ms '
        'pointers=$_pointers',
      );
    }
    _frames.clear();
    _pointers = 0;
    _variantStart = DateTime.now();
    setState(() {
      _v = (_v + 1) % _variants.length;
      if (_v == 0) _round++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final (label, ticker, boundary, spinner) = _variants[_v];
    final rows = <Widget>[
      for (var i = 0; i < _dots; i++)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              _Dot(ticker: ticker, boundary: boundary),
              const SizedBox(width: 8),
              Expanded(child: Text('session $i — review architecture doc')),
            ],
          ),
        ),
    ];
    // The shimmer + spinner go FIRST: a ListView builds children lazily, so a
    // row past the fold is never instantiated and its ticker never runs — which
    // silently made an earlier version of this bench measure nothing.
    final transcript = <Widget>[
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            _Shimmer(ticker: ticker, boundary: boundary),
            const SizedBox(width: 12),
            switch (spinner) {
              'material' => const SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              'pulse' => const PulseSpinner(size: 10),
              _ => const SizedBox.shrink(),
            },
          ],
        ),
      ),
      for (var i = 0; i < 40; i++)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'line $i · ${'the quick brown fox jumps over the lazy dog. ' * 2}',
          ),
        ),
    ];
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Listener(
        onPointerDown: (_) => _pointers++,
        onPointerMove: (_) => _pointers++,
        onPointerSignal: (_) => _pointers++,
        child: Scaffold(
          appBar: AppBar(title: Text('$label · host=$_host · do not touch')),
          // KeyedSubtree per variant: a switch rebuilds from scratch rather than
          // updating in place, so no layer survives across arms.
          body: KeyedSubtree(
            key: ValueKey('$label-$_round'),
            child: Row(
              children: [
                SizedBox(width: 260, child: _host2(rows)),
                Expanded(child: _host2(transcript)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// ListView adds a RepaintBoundary per child by default; Column does not.
  Widget _host2(List<Widget> children) => _host == 'column'
      ? SingleChildScrollView(child: Column(children: children))
      : ListView(children: children);
}

Widget _plainDot(double alpha) => Container(
  width: 8,
  height: 8,
  decoration: BoxDecoration(
    color: Colors.greenAccent.withValues(alpha: alpha),
    shape: BoxShape.circle,
  ),
);

class _Dot extends StatelessWidget {
  const _Dot({required this.ticker, required this.boundary});

  final bool ticker;
  final bool boundary;

  @override
  Widget build(BuildContext context) {
    final Widget dot = ticker ? const _TickerDot() : const _ClockDot();
    return boundary ? RepaintBoundary(child: dot) : dot;
  }
}

/// The shared-clock dot, deliberately *not* built on [PulseBuilder]: that ships
/// a RepaintBoundary of its own, which would make the `NoRB` arms untrue and
/// double-wrap the `RB` ones. This is the boundary-free implementation the
/// header's numbers were measured against; the `boundary` flag adds the layer.
class _ClockDot extends StatelessWidget {
  const _ClockDot();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: PulseClock.instance,
    builder: (context, _) => _plainDot(
      0.3 +
          0.7 *
              pulseValue(
                PulseClock.instance.elapsed,
                const Duration(milliseconds: 900),
                reverse: true,
              ),
    ),
  );
}

class _Shimmer extends StatelessWidget {
  const _Shimmer({required this.ticker, required this.boundary});

  final bool ticker;
  final bool boundary;

  @override
  Widget build(BuildContext context) {
    // Same reason as [_ClockDot]: boundary-free, so the flag alone decides.
    final Widget shimmer = ticker
        ? const _TickerShimmer()
        : ListenableBuilder(
            listenable: PulseClock.instance,
            builder: (context, _) => _mask(
              pulseValue(
                PulseClock.instance.elapsed,
                const Duration(milliseconds: 1400),
              ),
            ),
          );
    return boundary ? RepaintBoundary(child: shimmer) : shimmer;
  }
}

Widget _mask(double t) => ShaderMask(
  blendMode: BlendMode.srcIn,
  shaderCallback: (bounds) => LinearGradient(
    colors: const [Colors.white24, Colors.white, Colors.white24],
    stops: const [0.35, 0.5, 0.65],
    transform: _Slide(t),
  ).createShader(bounds),
  child: const Text('Thinking'),
);

/// The pre-optimisation dot: repeating controller at vsync + opacity layer.
class _TickerDot extends StatefulWidget {
  const _TickerDot();

  @override
  State<_TickerDot> createState() => _TickerDotState();
}

class _TickerDotState extends State<_TickerDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: 0.3, end: 1).animate(_c),
    child: _plainDot(1),
  );
}

/// The pre-optimisation shimmer: ShaderMask driven at vsync.
class _TickerShimmer extends StatefulWidget {
  const _TickerShimmer();

  @override
  State<_TickerShimmer> createState() => _TickerShimmerState();
}

class _TickerShimmerState extends State<_TickerShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _c, builder: (_, _) => _mask(_c.value));
}

class _Slide extends GradientTransform {
  const _Slide(this.t);
  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 2 - 1), 0, 0);
}
