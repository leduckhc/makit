// Interleaved A/B bench for the idle-cost work. Throwaway: not referenced by
// the app. Companion to pulse_bench.dart, which proved cadence is the only lever
// on Impeller's raster cost. This bench measures the unexploited lever: not
// ticking at all.
//
// It models the reported live case — ~8 sessions, most parked — and cycles four
// arms in ONE process every 4s, so machine drift and stray interaction cannot
// land on a single arm. Each window reports pointer events; discard any window
// with pointers > 0.
//
//   flutter run --profile -d macos -t tool/perf/pulse_idle_bench.dart
//
// MAXIMIZE the window before reading numbers. The idle cost scales with pixel
// count: the win is largest on a maximized window on a high-resolution panel,
// which is exactly the reported case (a maximized window on a 6400x3600 panel).
//
// Arms (8 dots each, matching the reported parked-session count):
//   parkedOld   all 8 dots pulse (the shipped-before behaviour: running +
//               awaitingInput + awaitingApproval all pulsed)
//   parkedNew   all 8 dots are parked and solid (only `running` pulses now)
//   oneRunning  1 running dot pulses, 7 parked dots are solid
//   hidden      parkedNew, but the pulse clock is paused (window not visible)
//
// Expected reading: parkedOld ticks the shared clock at 20 fps forever;
// parkedNew and hidden schedule ~0 fps; oneRunning holds ~20 fps for the one
// live dot. Report frames/s, UI-thread build ms and raster ms per window, and
// state the window size you measured at.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:makit/ui/widgets/pulse.dart';
import 'package:window_manager/window_manager.dart';

/// (label, number of dots that pulse, pause the clock)
const _variants = <(String, int, bool)>[
  ('parkedOld', 8, false),
  ('parkedNew', 0, false),
  ('oneRunning', 1, false),
  ('hidden', 0, true),
];

const _dots = 8;
const _hold = Duration(seconds: 4);
const _settle = Duration(seconds: 1);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The idle cost scales with pixel count, so measure a maximized window.
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(null, () async {
    await windowManager.maximize();
    await windowManager.show();
  });
  runApp(const _BenchApp());
}

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
  Size _viewSize = Size.zero;
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
    // Leave the shared clock visible again for the next arm.
    PulseClock.instance.setVisible(true);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
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
        'BENCH round=$_round variant=${_variants[_v].$1} '
        'fps=${fps.toStringAsFixed(1)} frames=$n win=${elapsed.inMilliseconds}ms '
        'build=${total((t) => t.buildDuration.inMicroseconds).toStringAsFixed(1)}ms '
        'raster=${total((t) => t.rasterDuration.inMicroseconds).toStringAsFixed(1)}ms '
        'px=${_viewSize.width.toInt()}x${_viewSize.height.toInt()} '
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
    final (label, pulsing, hidden) = _variants[_v];
    // Drive the visibility seam exactly as the app's IdleReclaimObserver does.
    PulseClock.instance.setVisible(!hidden);
    final view = View.of(context).physicalSize;
    _viewSize = view;
    final rows = <Widget>[
      for (var i = 0; i < _dots; i++)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              _Dot(pulses: i < pulsing),
              const SizedBox(width: 8),
              Expanded(child: Text('session $i — waiting on you')),
            ],
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
          appBar: AppBar(
            title: Text(
              '$label · ${view.width.toInt()}x${view.height.toInt()}px · '
              'do not touch',
            ),
          ),
          body: KeyedSubtree(
            key: ValueKey('$label-$_round'),
            child: SingleChildScrollView(child: Column(children: rows)),
          ),
        ),
      ),
    );
  }
}

/// A pulsing dot uses the real [PulseBuilder]; a parked dot is a flat container,
/// mirroring [SessionStatusDot] exactly.
class _Dot extends StatelessWidget {
  const _Dot({required this.pulses});

  final bool pulses;

  @override
  Widget build(BuildContext context) {
    Widget dotAt(double alpha) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: Colors.greenAccent.withValues(alpha: alpha),
        shape: BoxShape.circle,
      ),
    );
    return pulses
        ? PulseBuilder(builder: (context, t) => dotAt(0.3 + 0.7 * t))
        : dotAt(1);
  }
}
