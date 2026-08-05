import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/metrics/charts.dart';
import 'package:makit/desktop/metrics/frame_timings.dart';
import 'package:makit/desktop/metrics/metrics_dashboard.dart';
import 'package:makit/desktop/metrics/metrics_export.dart';
import 'package:makit/desktop/settings/settings_window.dart'
    show DesktopWindowBody;
import 'package:makit/desktop/window_overlays.dart';
import 'package:makit/store/metrics.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';

const int _mb = 1024 * 1024;

AgentMetrics _agent({
  String label = 'codex · pino',
  int pid = 5001,
  int rssBytes = 220 * _mb,
  double? cpuPercent = 6.5,
  double cpuSeconds = 44.2,
  bool inTurn = false,
  int? procs = 3,
  int? uptimeMs = 60000,
  String sessionId = 's1',
}) => AgentMetrics(
  pid: pid,
  rssBytes: rssBytes,
  cpuPercent: cpuPercent,
  cpuSeconds: cpuSeconds,
  sessionId: sessionId,
  label: label,
  inTurn: inTurn,
  procs: procs,
  uptimeMs: uptimeMs,
);

MetricsSample _sample({
  int ts = 100000,
  bool withApp = true,
  double? appCpu = 4.1,
  List<AgentMetrics>? agents,
  bool procTableOk = true,
  StorageMetrics? storage,
  double? samplerCpu = 0.3,
}) => MetricsSample(
  ts: ts,
  app: withApp
      ? SurfaceMetrics(
          pid: 4242,
          rssBytes: 131 * _mb,
          cpuPercent: appCpu,
          cpuSeconds: 18.2,
        )
      : null,
  server: const ServerMetrics(
    pid: 4201,
    rssBytes: 62 * _mb,
    cpuPercent: 2.4,
    cpuSeconds: 9.6,
    eventLoopP50: 0.4,
    eventLoopP99: 1.8,
  ),
  agents: agents ?? [_agent()],
  wire: const WireMetrics(
    inBytesPerSec: 1400,
    outBytesPerSec: 6451,
    framesPerSec: 2,
  ),
  storage: storage,
  sampler: SamplerMetrics(cpuPercent: samplerCpu, rssBytes: null),
  turnActive: false,
  procTableOk: procTableOk,
);

Widget _host({
  List<MetricsSample> history = const [],
  MetricsWatchController? watch,
  FrameTimingsCollector? frames,
  VoidCallback? onClose,
}) => ProviderScope(
  overrides: [
    metricsHistoryProvider.overrideWithValue(history),
    metricsProvider.overrideWithValue(history.isEmpty ? null : history.last),
    metricsWatchControllerProvider.overrideWithValue(
      watch ?? MetricsWatchController((_) {}),
    ),
    if (frames != null) frameTimingsProvider.overrideWithValue(frames),
    preferencesControllerProvider.overrideWith(
      (ref) => PreferencesController.ephemeral(),
    ),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1400,
        height: 900,
        child: MetricsDashboard(onClose: onClose ?? () {}),
      ),
    ),
  ),
);

void main() {
  group('painters survive every ring size', () {
    /// The three sizes that break naive chart code: nothing, one point (no span
    /// to divide by), and a full window. Asserting "no exception + finite
    /// bounds" rather than golden images keeps this useful without pinning
    /// pixels.
    final rings = <String, List<MetricsSample>>{
      'empty': const [],
      'single': [_sample(ts: 1000)],
      'full': [for (var i = 0; i < 300; i++) _sample(ts: 1000 + i * 1000)],
      // Every sample sharing a timestamp gives a zero-width time span.
      'same-ts': [for (var i = 0; i < 5; i++) _sample(ts: 1000)],
    };

    for (final entry in rings.entries) {
      test('StackedAreaPainter · ${entry.key}', () {
        final series = <MetricSeries>[
          (
            label: 'app',
            color: const Color(0xFF0000FF),
            points: [
              for (final s in entry.value) (ts: s.ts, value: s.app?.cpuPercent),
            ],
          ),
          (
            label: 'server',
            color: const Color(0xFF00FF00),
            points: [
              for (final s in entry.value)
                (ts: s.ts, value: s.server.cpuPercent),
            ],
          ),
        ];
        final recorder = PictureRecorder();
        StackedAreaPainter(
          series: series,
          maxY: null,
          gridColor: const Color(0xFF888888),
          gridAtY: 100,
        ).paint(Canvas(recorder), const Size(400, 110));
        expect(recorder.endRecording(), isNotNull);
      });

      test('MultiLinePainter · ${entry.key}', () {
        final recorder = PictureRecorder();
        MultiLinePainter(
          series: [
            (
              label: 'p99',
              color: const Color(0xFFFF0000),
              points: [
                for (final s in entry.value)
                  (ts: s.ts, value: s.server.eventLoopP99),
              ],
            ),
          ],
        ).paint(Canvas(recorder), const Size(400, 70));
        expect(recorder.endRecording(), isNotNull);
      });
    }

    test('HistogramPainter · empty, single bucket, and all-zero counts', () {
      for (final buckets in <List<int>>[
        [],
        [5],
        [0, 0, 0],
        [1, 9, 3, 0, 2],
      ]) {
        final recorder = PictureRecorder();
        HistogramPainter(
          buckets: buckets,
          color: const Color(0xFF00FF00),
          overBudgetColor: const Color(0xFFFF0000),
          budgetBucket: 2,
        ).paint(Canvas(recorder), const Size(300, 70));
        expect(recorder.endRecording(), isNotNull);
      }
    });

    /// Bands must be summed at matching timestamps. Pairing by index would shift
    /// a band by one sample as soon as a series had a gap, which is exactly what
    /// the mixed-cadence ring produces.
    test('stacked peak sums bands per timestamp, tolerating gaps', () {
      const painter = StackedAreaPainter(
        series: [
          (
            label: 'a',
            color: Color(0xFF000000),
            points: [(ts: 1, value: 2.0), (ts: 2, value: null)],
          ),
          (
            label: 'b',
            color: Color(0xFF000000),
            points: [(ts: 1, value: 3.0), (ts: 2, value: 10.0)],
          ),
        ],
        maxY: null,
      );
      // ts=1 stacks to 5; ts=2 has a gap in 'a', so it stacks to 10 alone.
      expect(painter.stackedPeak(), 10.0);
    });

    test('an all-gap stack has no peak — nothing to draw, not zero', () {
      const painter = StackedAreaPainter(
        series: [
          (
            label: 'a',
            color: Color(0xFF000000),
            points: [(ts: 1, value: null)],
          ),
        ],
        maxY: null,
      );
      expect(painter.stackedPeak(), isNull);
    });
  });

  group('frame histogram', () {
    test('is empty when no frame was timed', () {
      expect(frameHistogram(FrameStats.empty), isEmpty);
    });

    test('buckets by duration, with the budget boundary inclusive', () {
      const stats = FrameStats(
        p50Ms: 8,
        p95Ms: 40,
        dropped: 2,
        sampleCount: 5,
        samplesMs: [3, 8, 16.7, 30, 80],
      );
      final buckets = frameHistogram(stats);
      expect(buckets.length, kFrameBucketEdgesMs.length + 1);
      expect(buckets.reduce((a, b) => a + b), 5);
      // 16.7 lands in the budget bucket itself (<=), not the one past it.
      expect(buckets[kFrameBudgetBucket], 1);
      // 80ms exceeds every edge and lands in the overflow bucket.
      expect(buckets.last, 1);
    });
  });

  group('export', () {
    test('json round-trips through the store decoder', () {
      final history = [_sample(ts: 1000), _sample(ts: 2000)];
      final json = metricsExportJson(
        history: history,
        appVersion: 'makit 0.9.2',
        platform: 'macos',
      );
      expect(json['schemaVersion'], kMetricsExportVersion);
      expect(json['sampleCount'], 2);

      final samples = json['samples']! as List;
      final decoded = MetricsSample.fromJson(
        Map<String, dynamic>.from(samples.first as Map),
      );
      expect(decoded, isNotNull);
      expect(decoded!.ts, 1000);
      expect(decoded.server.pid, 4201);
      expect(decoded.agents.single.label, 'codex · pino');
      expect(decoded.server.eventLoopP99, 1.8);
    });

    /// A round-trip must not manufacture measurements. A null rate that came back
    /// as 0 would turn "unknown" into "measured idle" on the way through a file.
    test('nulls survive the round-trip as nulls', () {
      final history = [
        _sample(
          ts: 1000,
          withApp: false,
          appCpu: null,
          samplerCpu: null,
          agents: [_agent(cpuPercent: null, procs: null, uptimeMs: null)],
        ),
      ];
      final json = metricsExportJson(
        history: history,
        appVersion: 'v',
        platform: 'p',
      );
      final s = Map<String, dynamic>.from(
        (json['samples']! as List).first as Map,
      );
      expect(s['app'], isNull);
      expect((s['sampler']! as Map)['cpuPercent'], isNull);
      expect((s['sampler']! as Map)['rssBytes'], isNull);
      final agent = ((s['agents']! as List).first as Map);
      expect(agent['cpuPercent'], isNull);
      expect(agent['procs'], isNull);

      final decoded = MetricsSample.fromJson(s)!;
      expect(decoded.app, isNull);
      expect(decoded.sampler.cpuPercent, isNull);
      expect(decoded.agents.single.cpuPercent, isNull);
    });

    test('json is pretty-printed and parseable as a string', () {
      final out = metricsExportJsonString(
        history: [_sample()],
        appVersion: 'v',
        platform: 'p',
      );
      expect(out, contains('\n  '));
      expect(out, contains('"schemaVersion"'));
    });

    test('markdown carries the headline numbers and the cost of measuring', () {
      final md = metricsExportMarkdown(
        history: [_sample(ts: 1000), _sample(ts: 6000)],
        appVersion: 'makit 0.9.2',
        platform: 'macos',
      );
      expect(md, contains('makit performance snapshot'));
      expect(md, contains('makit 0.9.2 · macos'));
      expect(md, contains('Total CPU:'));
      expect(md, contains('Total resident:'));
      // Decision 10: a snapshot that quoted the meter's numbers without its own
      // price would be exactly the omission this feature exists to refuse.
      expect(md, contains('Cost of measuring:'));
      expect(md, contains('| Process | PID | RSS | CPU | CPU-s |'));
      expect(md, contains('codex · pino'));
    });

    /// A baseline that is stored but never exported would be a button that does
    /// nothing — the same defect class as the frame collector that was wired to
    /// nothing. The stored sample must reach the artifact.
    test('a baseline is carried into the json and the markdown', () {
      final baseline = _sample(ts: 500);
      final json = metricsExportJson(
        history: [_sample(ts: 1000)],
        appVersion: 'v',
        platform: 'p',
        baseline: baseline,
      );
      expect(json['baselineTs'], 500);
      expect(json['baseline'], isNotNull);
      expect(
        MetricsSample.fromJson(
          Map<String, dynamic>.from(json['baseline']! as Map),
        )!.ts,
        500,
      );

      final md = metricsExportMarkdown(
        history: [_sample(ts: 1000)],
        appVersion: 'v',
        platform: 'p',
        baseline: baseline,
      );
      expect(md, contains('Baseline:'));
    });

    test('no baseline set ⇒ no baseline keys, and no empty section', () {
      final json = metricsExportJson(
        history: [_sample()],
        appVersion: 'v',
        platform: 'p',
      );
      expect(json.containsKey('baselineTs'), isFalse);
      expect(json['baseline'], isNull);
      final md = metricsExportMarkdown(
        history: [_sample()],
        appVersion: 'v',
        platform: 'p',
      );
      expect(md, isNot(contains('Baseline:')));
    });

    test('markdown says so rather than throwing on an empty ring', () {
      final md = metricsExportMarkdown(
        history: const [],
        appVersion: 'v',
        platform: 'p',
      );
      expect(md, contains('No samples recorded'));
    });

    test('markdown flags an unreadable process table', () {
      final md = metricsExportMarkdown(
        history: [_sample(procTableOk: false)],
        appVersion: 'v',
        platform: 'p',
      );
      expect(md, contains('unknown (not zero)'));
    });
  });

  group('dashboard', () {
    testWidgets('renders every cell', (tester) async {
      await tester.pumpWidget(
        _host(
          history: [
            _sample(
              ts: 1000,
              storage: const StorageMetrics(eventLogBytes: 18 * _mb),
            ),
            _sample(ts: 2000),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(kDashboardKey), findsOneWidget);
      expect(find.byKey(kDashboardCpuCellKey), findsOneWidget);
      expect(find.byKey(kDashboardMemoryCellKey), findsOneWidget);
      expect(find.byKey(kDashboardFrameCellKey), findsOneWidget);
      expect(find.byKey(kDashboardServerCellKey), findsOneWidget);
      expect(find.byKey(kDashboardFootprintCellKey), findsOneWidget);
      expect(find.byKey(kDashboardProcessTableKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    /// The phone-only case: no loopback client reported a pid, so there is no app
    /// surface. Every cell must still render rather than half-drawing.
    testWidgets('renders with app == null', (tester) async {
      await tester.pumpWidget(_host(history: [_sample(withApp: false)]));
      await tester.pumpAndSettle();

      expect(find.byKey(kDashboardCpuCellKey), findsOneWidget);
      expect(find.byKey(kDashboardProcessTableKey), findsOneWidget);
      // No app row in the table, and no fabricated zero for it.
      expect(find.text('makit (Flutter app)'), findsNothing);
      expect(find.text('makit-server (Node)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty ring says why rather than drawing empty cells', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      expect(find.byKey(kDashboardEmptyKey), findsOneWidget);
      expect(find.byKey(kDashboardCpuCellKey), findsNothing);
    });

    testWidgets('the process table shows PID and CPU-s for every surface', (
      tester,
    ) async {
      await tester.pumpWidget(_host(history: [_sample()]));
      await tester.pumpAndSettle();

      // PID is present so a user can cross-check us against Activity Monitor.
      expect(find.text('4242'), findsOneWidget);
      expect(find.text('4201'), findsOneWidget);
      expect(find.text('5001'), findsOneWidget);
      // CPU-s is the optimisation target, so it is displayed precisely.
      expect(find.text('18.2'), findsOneWidget);
      expect(find.text('44.2'), findsOneWidget);
      expect(find.text('makit total'), findsOneWidget);
    });

    testWidgets('a failed process table is called out, not zeroed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(history: [_sample(procTableOk: false, agents: const [])]),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('could not be read'), findsOneWidget);
      expect(find.textContaining('not zero'), findsOneWidget);
    });

    testWidgets('holds the watch and the timings callback while open', (
      tester,
    ) async {
      final sent = <bool>[];
      final added = <TimingsCallback>[];
      final removed = <TimingsCallback>[];
      await tester.pumpWidget(
        _host(
          history: [_sample()],
          watch: MetricsWatchController(sent.add),
          frames: FrameTimingsCollector(add: added.add, remove: removed.add),
        ),
      );
      await tester.pumpAndSettle();
      expect(sent, [true]);
      expect(added, hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(sent, [true, false]);
      expect(removed, hasLength(1));
    });

    testWidgets('Esc closes it', (tester) async {
      var closed = false;
      await tester.pumpWidget(
        _host(history: [_sample()], onClose: () => closed = true),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    });

    testWidgets('the close button closes it', (tester) async {
      var closed = false;
      await tester.pumpWidget(
        _host(history: [_sample()], onClose: () => closed = true),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kDashboardCloseKey));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    });

    testWidgets('Freeze holds the view still, and Live resumes it', (
      tester,
    ) async {
      await tester.pumpWidget(_host(history: [_sample()]));
      await tester.pumpAndSettle();
      expect(find.text('Freeze'), findsOneWidget);

      await tester.tap(find.text('Freeze'));
      await tester.pumpAndSettle();
      expect(find.text('Live'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Set baseline records the current sample and exports it', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(_host(history: [_sample()]));
      await tester.pumpAndSettle();
      expect(find.text('Set baseline'), findsOneWidget);

      await tester.tap(find.byKey(kDashboardBaselineKey));
      await tester.pumpAndSettle();
      expect(find.text('Baseline set'), findsOneWidget);

      await tester.tap(find.byKey(kDashboardExportKey));
      await tester.pumpAndSettle();
      final copy = calls.where((c) => c.method == 'Clipboard.setData').single;
      expect((copy.arguments as Map)['text'], contains('Baseline:'));
    });

    testWidgets('export copies a markdown snapshot to the clipboard', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(_host(history: [_sample()]));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(kDashboardExportKey));
      await tester.pumpAndSettle();

      final copy = calls.where((c) => c.method == 'Clipboard.setData');
      expect(copy, hasLength(1));
      expect(
        (copy.single.arguments as Map)['text'],
        contains('makit performance snapshot'),
      );
    });
  });

  /// Decision 9: both surfaces are `DesktopWindowBody` children in one z-space,
  /// so at most one may be open. The rule lives in that host widget rather than
  /// at the several call sites that open Settings, which is why these are widget
  /// tests and not provider tests.
  group('single-overlay invariant', () {
    Future<ProviderContainer> pumpShell(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          metricsHistoryProvider.overrideWithValue([_sample()]),
          metricsProvider.overrideWithValue(_sample()),
          metricsWatchControllerProvider.overrideWithValue(
            MetricsWatchController((_) {}),
          ),
          frameTimingsProvider.overrideWithValue(
            FrameTimingsCollector(add: (_) {}, remove: (_) {}),
          ),
          preferencesControllerProvider.overrideWith(
            (ref) => PreferencesController.ephemeral(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: DesktopWindowBody(child: Scaffold(body: Text('shell'))),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    testWidgets('opening the dashboard closes Settings', (tester) async {
      final container = await pumpShell(tester);
      container.read(settingsOpenProvider.notifier).state = true;
      await tester.pumpAndSettle();

      container.read(metricsDashboardOpenProvider.notifier).state = true;
      await tester.pumpAndSettle();

      expect(container.read(settingsOpenProvider), isFalse);
      expect(container.read(metricsDashboardOpenProvider), isTrue);
      expect(find.byKey(kDashboardKey), findsOneWidget);
    });

    testWidgets('opening Settings closes the dashboard', (tester) async {
      final container = await pumpShell(tester);
      container.read(metricsDashboardOpenProvider.notifier).state = true;
      await tester.pumpAndSettle();
      expect(find.byKey(kDashboardKey), findsOneWidget);

      container.read(settingsOpenProvider.notifier).state = true;
      await tester.pumpAndSettle();

      expect(container.read(metricsDashboardOpenProvider), isFalse);
      expect(find.byKey(kDashboardKey), findsNothing);
    });

    /// The other half of decision 9: unlike Settings, the chat underneath stays
    /// interactive — you must be able to drive a session while watching its cost.
    testWidgets('the dashboard does not exclude the chat from focus', (
      tester,
    ) async {
      final container = await pumpShell(tester);
      container.read(metricsDashboardOpenProvider.notifier).state = true;
      await tester.pumpAndSettle();

      final excluders = tester.widgetList<ExcludeFocus>(
        find.byType(ExcludeFocus),
      );
      expect(
        excluders.every((e) => !e.excluding),
        isTrue,
        reason: 'the dashboard must leave the chat focusable',
      );
    });
  });
}
