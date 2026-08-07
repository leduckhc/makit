import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/metrics/frame_timings.dart';
import 'package:makit/desktop/metrics/metrics_button.dart';
import 'package:makit/desktop/window_overlays.dart';
import 'package:makit/desktop/metrics/metrics_icon_state.dart';
import 'package:makit/store/metrics.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/ui/widgets/pulse.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

const int _mb = 1024 * 1024;

AgentMetrics _agent({
  required String label,
  int pid = 100,
  int rssBytes = 9 * _mb,
  double? cpuPercent = 0,
  bool inTurn = false,
  int? procs = 1,
  int? uptimeMs = 12 * 60 * 1000,
  String sessionId = 's1',
}) => AgentMetrics(
  pid: pid,
  rssBytes: rssBytes,
  cpuPercent: cpuPercent,
  cpuSeconds: 3,
  sessionId: sessionId,
  label: label,
  inTurn: inTurn,
  procs: procs,
  uptimeMs: uptimeMs,
);

MetricsSample _sample({
  int ts = 100000,
  double? appCpu = 0.3,
  double? serverCpu = 0.1,
  List<AgentMetrics>? agents,
  bool turnActive = false,
  bool procTableOk = true,
  bool withApp = true,
  double? samplerCpu = 0.1,
  int? samplerRss,
  StorageMetrics? storage,
}) => MetricsSample(
  ts: ts,
  app: withApp
      ? SurfaceMetrics(
          pid: 1,
          rssBytes: 118 * _mb,
          cpuPercent: appCpu,
          cpuSeconds: 4,
        )
      : null,
  server: ServerMetrics(
    pid: 2,
    rssBytes: 51 * _mb,
    cpuPercent: serverCpu,
    cpuSeconds: 2,
    eventLoopP50: 1.2,
    eventLoopP99: 1.8,
  ),
  agents: agents ?? [_agent(label: 'pi · makit')],
  wire: const WireMetrics(
    inBytesPerSec: 2048,
    outBytesPerSec: 1024,
    framesPerSec: 3,
  ),
  storage: storage,
  sampler: SamplerMetrics(cpuPercent: samplerCpu, rssBytes: samplerRss),
  turnActive: turnActive,
  procTableOk: procTableOk,
);

Widget _host({
  MetricsSample? sample,
  List<MetricsSample>? history,
  MetricsWatchController? watch,
  FrameTimingsCollector? frames,
  PreferencesController? prefs,
  double width = 900,
  double height = 700,
}) => ProviderScope(
  overrides: [
    metricsProvider.overrideWithValue(sample),
    metricsHistoryProvider.overrideWithValue(
      history ?? (sample == null ? const [] : [sample]),
    ),
    // Always overridden: the real controller issues a `cmd` over the socket,
    // which leaves a pending request timer and fails every test that merely
    // opens the panel.
    metricsWatchControllerProvider.overrideWithValue(
      watch ?? MetricsWatchController((_) {}),
    ),
    if (frames != null) frameTimingsProvider.overrideWithValue(frames),
    preferencesControllerProvider.overrideWith(
      (ref) => prefs ?? PreferencesController.ephemeral(),
    ),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          // Bottom-anchored like the real footer, so the popover opens upward.
          child: const Align(
            alignment: Alignment.bottomRight,
            child: MetricsButton(),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byIcon(PhosphorIconsLight.pulse).first);
  await tester.pumpAndSettle();
}

/// Opens without settling. Required whenever a turn is running: decision 12 shows
/// "working" as a *repeating* glyph animation instead of a tint, so the tree never
/// reaches a settled state and `pumpAndSettle` would time out.
Future<void> _openWhileWorking(WidgetTester tester) async {
  await tester.tap(find.byIcon(PhosphorIconsLight.pulse).first);
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  group('formatting', () {
    /// Decision 2: a null rate is `—`. A `0.0%` would read as a *measured* idle,
    /// which is a different and unearned claim.
    test('a null cpuPercent renders an em dash, never 0.0%', () {
      expect(formatCpu(null), '—');
      expect(formatCpu(0), '0.0%');
      expect(formatCpu(89.34), '89.3%');
    });

    test('an unknown byte figure is a dash, not a zero', () {
      // "not separately attributable" and "measured as zero" are different
      // claims; only the first is true of the sampler's resident size.
      expect(formatBytesOrDash(null), '—');
      expect(formatBytesOrDash(0), '0 B');
      expect(formatBytesOrDash(2 * _mb), '2 MB');
    });

    test('frame stats read as a dash until a frame is timed, never 0.0 ms', () {
      expect(formatFrameStats(FrameStats.empty), '—');
      expect(
        formatFrameStats(
          const FrameStats(p50Ms: 4, p95Ms: 7.9, dropped: 0, sampleCount: 10),
        ),
        '7.9 ms',
      );
      expect(
        formatFrameStats(
          const FrameStats(p50Ms: 4, p95Ms: 40, dropped: 3, sampleCount: 10),
        ),
        '40.0 ms · 3 dropped',
      );
    });

    test('bytes read as MB then GB with two decimals', () {
      expect(formatBytes(118 * _mb), '118 MB');
      expect(formatBytes((1.22 * 1024 * _mb).round()), '1.22 GB');
      expect(formatBytes(900), '900 B');
    });

    test('durations are coarse: seconds, minutes, then hours', () {
      expect(formatDuration(45000), '45s');
      expect(formatDuration(12 * 60 * 1000), '12m');
      expect(formatDuration((3 * 60 + 4) * 60 * 1000), '3h 04m');
    });
  });

  group('totals', () {
    test('total RSS sums app, server and every agent tree', () {
      final s = _sample(
        agents: [
          _agent(label: 'a', rssBytes: 10 * _mb),
          _agent(label: 'b', rssBytes: 5 * _mb),
        ],
      );
      expect(metricsTotalRssBytes(s), (118 + 51 + 10 + 5) * _mb);
    });

    /// A surface whose rate is not yet computable must contribute *nothing*,
    /// not a zero — otherwise the total silently understates real load.
    test('agents CPU is null when no agent has a computable rate', () {
      final s = _sample(
        agents: [
          _agent(label: 'a', cpuPercent: null),
          _agent(label: 'b', cpuPercent: null),
        ],
      );
      expect(metricsAgentsCpuPercent(s), isNull);
    });

    test('agents CPU sums only the measurable ones', () {
      final s = _sample(
        agents: [
          _agent(label: 'a', cpuPercent: null),
          _agent(label: 'b', cpuPercent: 2.5),
        ],
      );
      expect(metricsAgentsCpuPercent(s), 2.5);
    });
  });

  group('window', () {
    /// The ring mixes 1 Hz and 5 s samples, so the window must be selected by
    /// time. Taking a fixed *count* would silently show 25 minutes of coarse
    /// history under a "last 5 minutes" label.
    test('keeps only samples within the window, by timestamp', () {
      final history = [
        _sample(ts: 1000),
        _sample(ts: 200000),
        _sample(ts: 400000),
      ];
      final window = metricsWindow(history, 400000, 5 * 60 * 1000);
      expect(window.map((s) => s.ts), [200000, 400000]);
    });
  });

  group('popover', () {
    testWidgets('renders the pulse glyph in the footer', (tester) async {
      await tester.pumpWidget(_host(sample: _sample()));
      expect(find.byIcon(PhosphorIconsLight.pulse), findsOneWidget);
    });

    testWidgets('the working glyph pulses off the shared clock, not at vsync', (
      tester,
    ) async {
      await tester.pumpWidget(_host(sample: _sample(turnActive: true)));
      await tester.pump();

      // Decision 12's repeating glyph must not hold the compositor at the
      // display refresh rate — it animates on the shared 20 Hz pulse clock.
      expect(find.byType(PulseBuilder), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a parked footer leaves nothing pulsing', (tester) async {
      await tester.pumpWidget(_host(sample: _sample()));
      await tester.pumpAndSettle();
      expect(find.byType(PulseBuilder), findsNothing);
    });

    testWidgets('opens on tap and closes on Esc', (tester) async {
      await tester.pumpWidget(_host(sample: _sample()));
      expect(find.byKey(kMetricsPopoverKey), findsNothing);

      await _open(tester);
      expect(find.byKey(kMetricsPopoverKey), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(kMetricsPopoverKey), findsNothing);
    });

    testWidgets('closes on an outside tap', (tester) async {
      await tester.pumpWidget(_host(sample: _sample()));
      await _open(tester);
      expect(find.byKey(kMetricsPopoverKey), findsOneWidget);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byKey(kMetricsPopoverKey), findsNothing);
    });

    testWidgets('headline totals every surface', (tester) async {
      await tester.pumpWidget(
        _host(
          sample: _sample(
            agents: [_agent(label: 'pi', rssBytes: 9 * _mb)],
          ),
        ),
      );
      await _open(tester);
      // 118 + 51 + 9 = 178 MB, 0.3 + 0.1 + 0.0 = 0.4% CPU.
      expect(find.text('178'), findsOneWidget);
      expect(find.textContaining('MB total · 0.4% CPU'), findsOneWidget);
    });

    testWidgets('an unmeasurable app CPU renders — rather than 0.0%', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          sample: _sample(
            appCpu: null,
            serverCpu: null,
            agents: [_agent(label: 'pi', cpuPercent: null)],
          ),
        ),
      );
      await _open(tester);
      // Every surface row, plus the headline's total, must read the dash.
      expect(find.text('—'), findsWidgets);
      expect(find.textContaining('0.0%'), findsNothing);
    });

    /// Decision 13 — the SPEC-32 vanishing-pill defect in a new hat. A failed
    /// `ps` must say so; it must not render zeros (which read as "idle") and
    /// must not silently drop the agents (which reads as "exited").
    testWidgets('a failed process table says measurement unavailable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(sample: _sample(procTableOk: false, agents: const [])),
      );
      await _open(tester);

      expect(find.byKey(kMetricsUnavailableKey), findsOneWidget);
      expect(find.textContaining('Measurement unavailable'), findsOneWidget);
      expect(find.byKey(kMetricsAgentListKey), findsNothing);
      // The server row survives — it needs no `ps` — which is what proves this
      // is a measurement failure rather than an empty machine.
      expect(find.text('Server (Node)'), findsOneWidget);
      expect(find.text('51 MB'), findsOneWidget);
    });

    testWidgets('agent rows are sorted by resident size, largest first', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          sample: _sample(
            agents: [
              _agent(label: 'small · a', rssBytes: 4 * _mb, sessionId: 'a'),
              _agent(label: 'huge · b', rssBytes: 900 * _mb, sessionId: 'b'),
              _agent(label: 'mid · c', rssBytes: 40 * _mb, sessionId: 'c'),
            ],
          ),
        ),
      );
      await _open(tester);

      final dy = <String, double>{};
      for (final label in ['huge · b', 'mid · c', 'small · a']) {
        dy[label] = tester.getTopLeft(find.text(label)).dy;
      }
      expect(dy['huge · b']!, lessThan(dy['mid · c']!));
      expect(dy['mid · c']!, lessThan(dy['small · a']!));
    });

    testWidgets('a long agent label does not overflow the 300pt popover', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          sample: _sample(
            agents: [
              _agent(
                label:
                    'codex · a-very-long-repository-name-that-would-run-off '
                    'the-edge-of-the-panel',
              ),
            ],
          ),
        ),
      );
      await _open(tester);
      // A RenderFlex overflow would have been recorded as an exception here.
      expect(tester.takeException(), isNull);
      expect(find.byKey(kMetricsPopoverKey), findsOneWidget);
    });

    testWidgets('coarse frames omit procs/uptime without printing 0', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          sample: _sample(
            agents: [_agent(label: 'pi · makit', procs: null, uptimeMs: null)],
          ),
        ),
      );
      await _open(tester);
      expect(find.text('parked'), findsOneWidget);
      expect(find.textContaining('0 proc'), findsNothing);
      expect(find.textContaining('up 0s'), findsNothing);
    });

    testWidgets('an in-turn agent reads as in turn, not parked', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          sample: _sample(
            turnActive: true,
            agents: [_agent(label: 'codex · pino', inTurn: true, procs: 6)],
          ),
        ),
      );
      await _openWhileWorking(tester);
      expect(find.textContaining('in turn'), findsWidgets);
      expect(
        find.textContaining('1 turn running — codex · pino'),
        findsOneWidget,
      );
    });

    /// F3 (review): `turnActive` is the authoritative turn signal. The collector
    /// deliberately omits sessions with no pid (decision 11) while still setting
    /// `turnActive`, so reading working state off `agents` alone made the panel
    /// print "idle" while the footer glyph animated as Working — one panel
    /// asserting two contradictory things.
    testWidgets(
      'a turn with no measurable agent still reads as running, not idle',
      (tester) async {
        await tester.pumpWidget(
          _host(sample: _sample(turnActive: true, agents: const [])),
        );
        await _openWhileWorking(tester);

        expect(find.textContaining('idle'), findsNothing);
        expect(find.textContaining('turn running'), findsOneWidget);
      },
    );

    testWidgets('a named in-turn agent is still named', (tester) async {
      await tester.pumpWidget(
        _host(
          sample: _sample(
            turnActive: true,
            agents: [_agent(label: 'codex · pino', inTurn: true)],
          ),
        ),
      );
      await _openWhileWorking(tester);
      expect(
        find.textContaining('1 turn running — codex · pino'),
        findsOneWidget,
      );
    });

    testWidgets('no turn plus parked agents still reads idle', (tester) async {
      await tester.pumpWidget(
        _host(
          sample: _sample(agents: [_agent(label: 'pi · makit')]),
        ),
      );
      await _open(tester);
      expect(find.textContaining('idle — no turn running'), findsOneWidget);
      expect(find.textContaining('1 agent parked'), findsOneWidget);
    });

    /// A11y: the rows are a `Row` of `Text`s plus a `CustomPaint`, which a screen
    /// reader cannot assemble into a reading. Each row states its own numbers.
    testWidgets('surface and agent rows carry semantic labels with numbers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          sample: _sample(agents: [_agent(label: 'pi · makit', cpuPercent: 0)]),
        ),
      );
      await _open(tester);

      expect(
        find.bySemanticsLabel('Server (Node), 51 MB resident, 0.1% CPU'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'pi · makit, parked · up 12m · 1 proc, 9 MB resident, 0.0% CPU',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('before the first sample the panel says so, without zeros', (
      tester,
    ) async {
      await tester.pumpWidget(_host(sample: null));
      await _open(tester);
      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('No reading yet'), findsOneWidget);
      expect(find.textContaining('MB total'), findsNothing);
    });
  });

  group('History expander', () {
    testWidgets('collapsed by default; the pill reveals the detail', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          sample: _sample(storage: const StorageMetrics(eventLogBytes: 4096)),
        ),
      );
      await _open(tester);
      expect(find.byKey(kMetricsSelfCostKey), findsNothing);

      await tester.tap(find.byKey(kMetricsHistoryPillKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kMetricsSelfCostKey), findsOneWidget);
    });

    /// F4 (review): the server refreshes `storage` only every 6th tick, so at
    /// 1 Hz the latest sample carries null five times out of six. Reading only
    /// the latest sample made the Event log row appear, vanish for ~5s, and
    /// reappear. The last measurement is still the truth until a newer one lands.
    testWidgets(
      'the event log row survives ticks that did not refresh storage',
      (tester) async {
        final measured = _sample(
          ts: 1000,
          storage: const StorageMetrics(eventLogBytes: 4096),
        );
        final unmeasured = _sample(ts: 2000);
        await tester.pumpWidget(
          _host(sample: unmeasured, history: [measured, unmeasured]),
        );
        await _open(tester);
        await tester.tap(find.byKey(kMetricsHistoryPillKey));
        await tester.pumpAndSettle();

        expect(find.text('Event log'), findsOneWidget);
        expect(find.textContaining('4 kB'), findsOneWidget);
      },
    );

    testWidgets('the event log row is absent when storage was never measured', (
      tester,
    ) async {
      await tester.pumpWidget(_host(sample: _sample()));
      await _open(tester);
      await tester.tap(find.byKey(kMetricsHistoryPillKey));
      await tester.pumpAndSettle();
      // Never measured is not "0 bytes" — say nothing rather than invent a size.
      expect(find.text('Event log'), findsNothing);
    });

    /// Decision 10: the panel displays its own cost. If this row can be removed
    /// without a test failing, the honesty claim is unenforced.
    testWidgets('the detail shows the sampler\'s own cost', (tester) async {
      await tester.pumpWidget(_host(sample: _sample(samplerCpu: 0.2)));
      await _open(tester);
      await tester.tap(find.byKey(kMetricsHistoryPillKey));
      await tester.pumpAndSettle();

      expect(find.text('This panel'), findsOneWidget);
      // Decision 16: the CPU cost is real; the resident figure is unknown, and
      // it reads as unknown instead of restating the server's RSS.
      expect(find.textContaining('0.2% CPU · —'), findsOneWidget);
    });

    /// The regression this guards: `sampler.rssBytes` used to carry
    /// `process.memoryUsage().rss`, so the "this panel" row reported the whole
    /// server's resident size as the measurement's own cost — the same number
    /// already shown one row above. A dash is the honest reading.
    testWidgets('the self-cost row never restates the server RSS', (
      tester,
    ) async {
      await tester.pumpWidget(_host(sample: _sample()));
      await _open(tester);
      await tester.tap(find.byKey(kMetricsHistoryPillKey));
      await tester.pumpAndSettle();

      final row = find.descendant(
        of: find.byKey(kMetricsSelfCostKey),
        matching: find.byType(Text),
      );
      final texts = tester.widgetList<Text>(row).map((t) => t.data).join(' ');
      expect(texts, contains('—'));
      expect(texts, isNot(contains('51 MB')));
    });

    testWidgets(
      'a known sampler RSS is still rendered when the server sends one',
      (tester) async {
        await tester.pumpWidget(_host(sample: _sample(samplerRss: 2 * _mb)));
        await _open(tester);
        await tester.tap(find.byKey(kMetricsHistoryPillKey));
        await tester.pumpAndSettle();
        expect(find.textContaining('2 MB'), findsWidgets);
      },
    );
  });

  group('watch ref-counting', () {
    /// The panel raises the sampler to 1 Hz only while it is open. A leaked
    /// watch would pin 1 Hz forever, in the feature whose claim is that makit is
    /// cheap when nobody is looking.
    testWidgets('opening watches and closing releases', (tester) async {
      final sent = <bool>[];
      await tester.pumpWidget(
        _host(sample: _sample(), watch: MetricsWatchController(sent.add)),
      );
      expect(sent, isEmpty);

      await _open(tester);
      expect(sent, [true]);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(sent, [true, false]);
    });

    testWidgets('a dispose while open still releases the watch', (
      tester,
    ) async {
      final sent = <bool>[];
      await tester.pumpWidget(
        _host(sample: _sample(), watch: MetricsWatchController(sent.add)),
      );
      await _open(tester);
      expect(sent, [true]);

      // Tear the whole tree down with the popover still showing.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(sent, [true, false]);
    });

    testWidgets('toggling twice does not stack watches', (tester) async {
      final sent = <bool>[];
      final controller = MetricsWatchController(sent.add);
      await tester.pumpWidget(_host(sample: _sample(), watch: controller));

      await _open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await _open(tester);

      expect(sent, [true, false, true]);
      expect(controller.watcherCount, 1);
    });
  });

  /// F1 (review): the collector existed, was unit-tested, and was wired to
  /// nothing — so the panel promised "UI frame times" in its History tooltip and
  /// never registered Flutter's timings callback. A unit test that never asserts
  /// the unit is REACHED passes happily while the feature is absent.
  group('frame timings wiring', () {
    ({
      FrameTimingsCollector collector,
      List<TimingsCallback> added,
      List<TimingsCallback> removed,
    })
    spy() {
      final added = <TimingsCallback>[];
      final removed = <TimingsCallback>[];
      return (
        collector: FrameTimingsCollector(add: added.add, remove: removed.add),
        added: added,
        removed: removed,
      );
    }

    testWidgets('opening the popover registers the timings callback', (
      tester,
    ) async {
      final s = spy();
      await tester.pumpWidget(_host(sample: _sample(), frames: s.collector));
      expect(s.added, isEmpty, reason: 'must not register while closed');

      await _open(tester);
      expect(s.added, hasLength(1));
      expect(s.collector.isRegistered, isTrue);
    });

    testWidgets('closing the popover removes it again', (tester) async {
      final s = spy();
      await tester.pumpWidget(_host(sample: _sample(), frames: s.collector));
      await _open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(s.removed, hasLength(1));
      expect(s.removed.single, same(s.added.single));
      expect(s.collector.isRegistered, isFalse);
    });

    testWidgets(
      'a dispose while open still removes it — a leaked callback is permanent',
      (tester) async {
        final s = spy();
        await tester.pumpWidget(_host(sample: _sample(), frames: s.collector));
        await _open(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        expect(s.removed, hasLength(1));
        expect(s.collector.isRegistered, isFalse);
      },
    );

    testWidgets('the History detail renders the measured frame p95', (
      tester,
    ) async {
      final added = <TimingsCallback>[];
      final collector = FrameTimingsCollector(add: added.add, remove: (_) {});
      await tester.pumpWidget(_host(sample: _sample(), frames: collector));
      await _open(tester);
      await tester.tap(find.byKey(kMetricsHistoryPillKey));
      await tester.pumpAndSettle();

      // Feed frames as the binding would.
      added.single([
        for (final ms in <double>[4, 5, 6, 40])
          FrameTiming(
            vsyncStart: 0,
            buildStart: 0,
            buildFinish: (ms * 500).round(),
            rasterStart: (ms * 500).round(),
            rasterFinish: (ms * 1000).round(),
            rasterFinishWallTime: (ms * 1000).round(),
          ),
      ]);
      // The row reads the ring during build, so it refreshes when the panel
      // rebuilds — in production that is the next `metrics.sample`, ~1/s. It is
      // deliberately NOT a per-frame notifier: rebuilding this panel at 60fps
      // would make the meter the cost it exists to measure. Collapse+expand is
      // the cheapest way to force that rebuild in a test.
      await tester.tap(find.byKey(kMetricsHistoryPillKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kMetricsHistoryPillKey));
      await tester.pumpAndSettle();

      expect(find.text('Frame p95'), findsOneWidget);
      expect(find.textContaining('40.0 ms'), findsOneWidget);
      // One frame over the 16.7ms budget must be reported as dropped.
      expect(find.textContaining('1 dropped'), findsOneWidget);
    });

    testWidgets('frame stats read as — before any frame is measured', (
      tester,
    ) async {
      final collector = FrameTimingsCollector(add: (_) {}, remove: (_) {});
      await tester.pumpWidget(_host(sample: _sample(), frames: collector));
      await _open(tester);
      await tester.tap(find.byKey(kMetricsHistoryPillKey));
      await tester.pumpAndSettle();

      expect(find.text('Frame p95'), findsOneWidget);
      // Not "0.0 ms": no frame has been timed, which is not a fast frame.
      expect(find.textContaining('0.0 ms'), findsNothing);
    });
  });

  group('Open dashboard', () {
    testWidgets('sets the dashboard flag and dismisses the popover', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            metricsProvider.overrideWithValue(_sample()),
            metricsHistoryProvider.overrideWithValue([_sample()]),
            metricsWatchControllerProvider.overrideWithValue(
              MetricsWatchController((_) {}),
            ),
            preferencesControllerProvider.overrideWith(
              (ref) => PreferencesController.ephemeral(),
            ),
          ],
          child: Consumer(
            builder: (ctx, ref, _) {
              container = ProviderScope.containerOf(ctx);
              return const MaterialApp(
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.bottomRight,
                    child: MetricsButton(),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await _open(tester);
      expect(container.read(metricsDashboardOpenProvider), isFalse);

      await tester.tap(find.byKey(kMetricsOpenDashboardKey));
      await tester.pumpAndSettle();

      expect(container.read(metricsDashboardOpenProvider), isTrue);
      expect(find.byKey(kMetricsPopoverKey), findsNothing);
    });
  });

  group('tooltip', () {
    test('names the state and carries the headline numbers', () {
      final s = _sample();
      expect(
        metricsTooltip(s, MetricsIconState.idle),
        contains('idle · 178 MB total · 0.4% CPU'),
      );
    });

    test('a failed process table is reported as unavailable, not as idle', () {
      expect(
        metricsTooltip(_sample(procTableOk: false), MetricsIconState.idle),
        contains('measurement unavailable'),
      );
    });

    test('no sample reads as not measured yet', () {
      expect(
        metricsTooltip(null, MetricsIconState.off),
        'Resource use — not measured yet',
      );
    });
  });
}
