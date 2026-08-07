// Streaming-transcript bench: how much UI-thread work one delta costs, and how
// that scales with message length. Throwaway, not referenced by the app.
//
//   flutter run --profile -d macos -t tool/perf/stream_bench.dart
//
// Why: the original profile showed ~17% of a core on the UI thread while a turn
// streams, unexplained by the animation work. chat_message.dart renders the
// whole message with `MarkdownBody(data: text)`, and flutter_markdown parses
// `data` during build — so every delta re-parses the entire message and rebuilds
// its subtree. If that is the cost, it grows with message length (quadratic over
// a reply), and coalescing deltas only helps if they arrive faster than the
// coalesce rate.
//
// Results (macOS/Impeller, profile build; medians of ~14 windows per arm):
//
//   arm              rebuilds  end chars  buildTotal  buildPerRebuild
//   md@1KB                 91      5.8 K     815.4ms          8.99ms
//   md@8KB                 91       13 K     919.7ms         10.12ms
//   md@20KB                90       25 K    1816.8ms         20.09ms
//   plain@20KB             90       25 K     921.7ms         10.23ms
//   coalesced@20KB         60       25 K    1238.2ms         20.63ms
//
// Reading:
//   * Cost scales with message length, not with delta size: one 40-char delta
//     against a 25KB message costs 20ms of UI thread, because every delta
//     re-pays for every character already there. 1817ms per 3s window is ~60%
//     of a core for the length of a long reply.
//   * MarkdownBody roughly doubles it (20.09ms against plain Text's 10.23ms at
//     the same 25KB) — but plain text alone is already 10ms, so text layout is
//     the floor and markdown is a 2x multiplier on top.
//   * Coalescing deltas DOES pay: 60 rebuilds instead of 90 cut total build
//     32% (1238ms against 1817ms), because per-rebuild cost barely moved
//     (20.63 against 20.09ms) — it is set by message length, not chunk size.
//
// Arms (interleaved in one process, 4s each, first 1s discarded):
//   md@1KB / md@8KB / md@20KB   real AgentMessage, rebuilt on every delta
//   plain@20KB                  same feed rendered as Text — the non-markdown floor
//   coalesced@20KB              real AgentMessage, rebuilt at the 20 Hz clock
//
// Read `buildPerRebuild` against `chars`: that pair decides whether markdown
// re-parse is the streaming cost, and how it scales with message length. Each arm
// starts at its labelled length and grows from there (append-only, like a real
// turn), so the label is a floor and `chars` reports where the window ended.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:makit/ui/session/chat_message.dart';
import 'package:makit/ui/widgets/pulse.dart';

/// Delta arrival rate. Agents emit at least this fast during a burst.
const Duration _deltaInterval = Duration(milliseconds: 33);

/// Characters appended per delta — a plausible token.
const int _chunkChars = 40;

const _hold = Duration(seconds: 4);
const _settle = Duration(seconds: 1);

/// (label, target length in chars, markdown?, coalesce to the pulse clock?)
const _arms = <(String, int, bool, bool)>[
  ('md@1KB', 1024, true, false),
  ('md@8KB', 8192, true, false),
  ('md@20KB', 20480, true, false),
  ('plain@20KB', 20480, false, false),
  ('coalesced@20KB', 20480, true, true),
];

void main() {
  // One-off micro-measurement: the style sheet is rebuilt on every message
  // build (chat_message.dart:_styleSheet), so its cost is paid per delta too.
  runApp(const _StreamBench());
}

class _StreamBench extends StatefulWidget {
  const _StreamBench();

  @override
  State<_StreamBench> createState() => _StreamBenchState();
}

class _StreamBenchState extends State<_StreamBench> {
  int _arm = 0;
  int _round = 0;
  final _frames = <FrameTiming>[];
  int _rebuilds = 0;
  int _chars = 0;
  late DateTime _armStart;
  Timer? _cycle;

  @override
  void initState() {
    super.initState();
    _armStart = DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _cycle = Timer.periodic(_hold, (_) => _next());
  }

  @override
  void dispose() {
    _cycle?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<FrameTiming> t) {
    if (DateTime.now().difference(_armStart) < _settle) return;
    _frames.addAll(t);
  }

  /// Counts a rebuild only inside the measured window. The numerator (frame
  /// timings) already excludes the settle second, so counting rebuilds from it
  /// would inflate the denominator and understate buildPerRebuild.
  void _countRebuild(int chars) {
    if (DateTime.now().difference(_armStart) < _settle) return;
    _rebuilds++;
    _chars = chars;
  }

  void _next() {
    final elapsed = DateTime.now().difference(_armStart) - _settle;
    if (_frames.isNotEmpty && elapsed.inMilliseconds > 0) {
      final buildMs =
          _frames
              .map((t) => t.buildDuration.inMicroseconds)
              .fold(0, (a, b) => a + b) /
          1000;
      final rasterMs =
          _frames
              .map((t) => t.rasterDuration.inMicroseconds)
              .fold(0, (a, b) => a + b) /
          1000;
      final perRebuild = _rebuilds == 0 ? 0.0 : buildMs / _rebuilds;
      // ignore: avoid_print
      print(
        'STREAM round=$_round arm=${_arms[_arm].$1} '
        'win=${elapsed.inMilliseconds}ms frames=${_frames.length} '
        'rebuilds=$_rebuilds chars=$_chars '
        'build=${buildMs.toStringAsFixed(1)}ms '
        'raster=${rasterMs.toStringAsFixed(1)}ms '
        'buildPerRebuild=${perRebuild.toStringAsFixed(2)}ms',
      );
    }
    _frames.clear();
    _rebuilds = 0;
    _chars = 0;
    _armStart = DateTime.now();
    setState(() {
      _arm = (_arm + 1) % _arms.length;
      if (_arm == 0) _round++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final (label, target, markdown, coalesce) = _arms[_arm];
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(title: Text('$label · do not touch')),
        body: Center(
          child: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: _StreamArm(
                // Rebuild the arm from scratch when it changes.
                key: ValueKey('$label-$_round'),
                targetChars: target,
                markdown: markdown,
                coalesce: coalesce,
                onRebuild: _countRebuild,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Feeds deltas into a message the way a streaming turn does.
class _StreamArm extends StatefulWidget {
  const _StreamArm({
    super.key,
    required this.targetChars,
    required this.markdown,
    required this.coalesce,
    required this.onRebuild,
  });

  final int targetChars;
  final bool markdown;

  /// Flush on the shared 20 Hz clock instead of on every delta.
  final bool coalesce;
  final void Function(int chars) onRebuild;

  @override
  State<_StreamArm> createState() => _StreamArmState();
}

class _StreamArmState extends State<_StreamArm> {
  // Prose with the markdown an agent actually emits: headers, lists, code, bold.
  static const _seed = '''
## Findings

Looking at `lib/store/store.dart`, the **delta path** rebuilds the whole item:

- it re-parses the message
- it rebuilds every child
- it reallocates the style sheet

```dart
void apply(Delta d) => items[d.seq] = items[d.seq].append(d.text);
```

That is fine for a short reply and quadratic for a long one, because each
delta pays for every character that came before it. ''';

  late String _text;
  String _pending = '';
  Timer? _feed;

  @override
  void initState() {
    super.initState();
    // Start AT the labelled length, not half of it: an arm that spends its window
    // climbing from 10KB to 15KB is not measuring a 20KB message.
    _text = _grow(widget.targetChars);
    _feed = Timer.periodic(_deltaInterval, (_) => _onDelta());
    if (widget.coalesce) PulseClock.instance.addListener(_flush);
  }

  @override
  void dispose() {
    _feed?.cancel();
    if (widget.coalesce) PulseClock.instance.removeListener(_flush);
    super.dispose();
  }

  String _grow(int chars) {
    final b = StringBuffer();
    while (b.length < chars) {
      b.write(_seed);
    }
    return b.toString().substring(0, chars);
  }

  void _onDelta() {
    _pending += _seed.substring(0, _chunkChars);
    if (!widget.coalesce) _flush();
  }

  /// Applies buffered deltas by appending only.
  ///
  /// Deliberately not a sliding window: trimming the head would change every
  /// character on every delta, so unchanged blocks would no longer compare equal
  /// and the arm would re-lay-out text that real streaming leaves alone —
  /// overstating the cost. Real streaming keeps a stable prefix and appends, so
  /// the message grows past the arm's label (~1.2KB/s at this feed); the reported
  /// `chars` is where it ended, making the label a floor rather than a fiction.
  void _flush() {
    if (_pending.isEmpty) return;
    setState(() {
      _text += _pending;
      _pending = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    widget.onRebuild(_text.length);
    return widget.markdown
        ? AgentMessage(text: _text, ts: 0)
        : Text(_text, style: Theme.of(context).textTheme.bodyMedium);
  }
}
