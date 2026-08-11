/// SPEC-37 Tier 2 — the full performance dashboard.
///
/// An in-window overlay (decision 9), opened from the Tier 1 popover's
/// `Open dashboard →`. Two properties distinguish it from Settings:
///
/// * The chat underneath stays **interactive** — no `ExcludeFocus`, no
///   `ExcludeSemantics`. You must be able to drive a session while watching what
///   it costs; that is the entire use case.
/// * It holds the 1 Hz metrics watch and the frame-timings callback for as long
///   as it is open, releasing both on dismiss (decisions 5 and 18).
///
/// Every cell answers a question a user can act on. Per the spec's non-goals
/// there is deliberately no live process-tree graph, no per-thread breakdown and
/// no flame chart: they look impressive and answer nothing this panel exists to
/// answer. The `CPU-s` column is the one to optimise against — instantaneous
/// CPU% flatters or damns depending on when you looked, while cumulative
/// CPU-seconds is stable and comparable between builds.
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import '../../store/metrics.dart';
import 'charts.dart';
import 'frame_timings.dart';
import 'metrics_button.dart';
import 'metrics_icon_state.dart' show metricsTotalCpuPercent;
import 'metrics_export.dart';

/// Test hooks.
const Key kDashboardKey = ValueKey('metrics-dashboard');
const Key kDashboardCpuCellKey = ValueKey('metrics-cell-cpu');
const Key kDashboardMemoryCellKey = ValueKey('metrics-cell-memory');
const Key kDashboardFrameCellKey = ValueKey('metrics-cell-frames');
const Key kDashboardServerCellKey = ValueKey('metrics-cell-server');
const Key kDashboardFootprintCellKey = ValueKey('metrics-cell-footprint');
const Key kDashboardProcessTableKey = ValueKey('metrics-process-table');
const Key kDashboardExportKey = ValueKey('metrics-export');
const Key kDashboardBaselineKey = ValueKey('metrics-set-baseline');
const Key kDashboardCloseKey = ValueKey('metrics-dashboard-close');
const Key kDashboardEmptyKey = ValueKey('metrics-dashboard-empty');

/// Frame-time histogram buckets, in ms. The 60 fps budget (16.7 ms) falls on a
/// bucket boundary so "over budget" is a visible cliff rather than a judgement.
const List<double> kFrameBucketEdgesMs = [4, 8, 12, 16.7, 24, 33, 50];

/// Index of the first **wholly** over-budget bucket.
///
/// Bucketing is `<= edge`, so bucket 3 is `(12, 16.7]` — still inside the 60 fps
/// budget. Pointing this at 3 painted every 13 ms frame, and an exactly-16.7 ms
/// frame, as though it had been dropped.
const int kFrameBudgetBucket = 4;

/// The Tier 2 dashboard overlay.
class MetricsDashboard extends ConsumerStatefulWidget {
  /// Creates the dashboard. [onClose] dismisses the overlay.
  const MetricsDashboard({required this.onClose, super.key});

  /// Invoked by `Esc` and the close affordance.
  final VoidCallback onClose;

  @override
  ConsumerState<MetricsDashboard> createState() => _MetricsDashboardState();
}

class _MetricsDashboardState extends ConsumerState<MetricsDashboard> {
  /// Both cached rather than re-read on release: `ref` is unsafe once the
  /// element is unmounting, so reading either from [dispose] would throw and
  /// leak the very costs this panel measures.
  MetricsWatchController? _held;
  FrameTimingsCollector? _frames;

  /// A frozen ring, or null while live. Freezing is not a pause of the sampler
  /// (that would change what is being measured); it holds the *view* still so a
  /// spike can be read after it has passed.
  List<MetricsSample>? _frozen;

  /// A stored "before" sample. Only ever compared by the reader of an exported
  /// snapshot: the side-by-side diff view is deferred until the numbers have
  /// proven interesting (spec non-goals), so this deliberately does not render a
  /// delta anywhere in the panel.
  MetricsSample? _baseline;

  @override
  void initState() {
    super.initState();
    final watch = ref.read(metricsWatchControllerProvider);
    _held = watch;
    watch.watch();
    final frames = ref.read(frameTimingsProvider);
    _frames = frames;
    frames.acquire();
  }

  @override
  void dispose() {
    _held?.release();
    _held = null;
    _frames?.release();
    _frames = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final live = ref.watch(metricsHistoryProvider);
    final history = _frozen ?? live;
    final latest = history.isEmpty ? null : history.last;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Focus(
        autofocus: true,
        child: Material(
          key: kDashboardKey,
          color: cs.surface,
          child: Column(
            children: [
              _Header(
                latest: latest,
                frozen: _frozen != null,
                onToggleFreeze: () =>
                    setState(() => _frozen = _frozen == null ? live : null),
                onClose: widget.onClose,
              ),
              Expanded(
                child: latest == null
                    ? const _Empty()
                    : _Body(history: history, latest: latest),
              ),
              _Footer(
                latest: latest,
                history: history,
                baseline: _baseline,
                onSetBaseline: latest == null
                    ? null
                    : () => setState(() => _baseline = latest),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.latest,
    required this.frozen,
    required this.onToggleFreeze,
    required this.onClose,
  });

  final MetricsSample? latest;
  final bool frozen;
  final VoidCallback onToggleFreeze;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace20,
        vertical: kSpace12,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(PhosphorIconsLight.pulse, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: kSpace10),
          Text(
            'Performance',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: kSpace12),
          Expanded(
            child: Text(
              latest == null
                  ? 'waiting for the first sample'
                  : latest!.procTableOk
                  ? '${formatBytes(metricsTotalRssBytes(latest!))} total · '
                        '${formatCpu(metricsTotalCpuPercent(latest!))} CPU'
                  // Not a partial total: with no process table there is no
                  // honest headline to give (decision 13).
                  : 'measurement unavailable — process table unreadable',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: onToggleFreeze,
            icon: Icon(
              frozen ? PhosphorIconsLight.play : PhosphorIconsLight.pause,
              size: 14,
            ),
            label: Text(frozen ? 'Live' : 'Freeze'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: cs.outlineVariant),
              foregroundColor: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: kSpace8),
          IconButton(
            key: kDashboardCloseKey,
            tooltip: 'Close (Esc)',
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
            icon: const Icon(PhosphorIconsLight.x, size: 16),
          ),
        ],
      ),
    );
  }
}

/// Before the first sample. Says why it is empty rather than drawing six empty
/// frames, which read as a rendering failure.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: kDashboardEmptyKey,
      child: Text(
        'No samples yet — the first one lands within a second.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.history, required this.latest});

  final List<MetricsSample> history;
  final MetricsSample latest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window = metricsWindow(history, latest.ts, kMetricsPopoverWindowMs);
    final stats = ref.read(frameTimingsProvider).stats;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(kSpace20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Two columns at desktop widths; the overlay is never narrow enough to
          // need a one-column fallback, and LayoutBuilder would add a branch no
          // test could meaningfully cover.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _CpuCell(window: window, latest: latest),
              ),
              const SizedBox(width: kSpace16),
              Expanded(
                child: _MemoryCell(window: window, latest: latest),
              ),
            ],
          ),
          const SizedBox(height: kSpace16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _FrameCell(stats: stats)),
              const SizedBox(width: kSpace16),
              Expanded(
                child: _ServerCell(window: window, latest: latest),
              ),
            ],
          ),
          const SizedBox(height: kSpace16),
          _FootprintCell(latest: latest, history: history),
          const SizedBox(height: kSpace16),
          _ProcessTable(latest: latest),
        ],
      ),
    );
  }
}

/// A titled cell with an explanatory caption — the caption is the point: a
/// number nobody can interpret cannot change a decision.
class _Cell extends StatelessWidget {
  const _Cell({
    super.key,
    required this.title,
    required this.caption,
    required this.child,
  });

  final String title;
  final String caption;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(kSpace16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kRadius12),
        border: Border.all(color: cs.outlineVariant),
        color: cs.surfaceContainerLow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Flexible(
                child: Text(
                  caption,
                  maxLines: 2,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: kSpace12),
          child,
        ],
      ),
    );
  }
}

/// Stacked CPU by surface, with a dashed one-core reference.
class _CpuCell extends StatelessWidget {
  const _CpuCell({required this.window, required this.latest});

  final List<MetricsSample> window;
  final MetricsSample latest;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Cell(
      key: kDashboardCpuCellKey,
      title: 'CPU — stacked by process',
      // The ceiling matters: on a 12-core machine 96% means "one core busy", not
      // "machine saturated", and the line is what makes that legible.
      caption: '% of one core · line = 1 core',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 110,
            child: CustomPaint(
              painter: StackedAreaPainter(
                series: [
                  (
                    label: 'app',
                    color: kBoardSwatch,
                    points: [
                      for (final s in window)
                        (ts: s.ts, value: s.app?.cpuPercent),
                    ],
                  ),
                  (
                    label: 'server',
                    color: kStatusWarning,
                    points: [
                      for (final s in window)
                        (ts: s.ts, value: s.server.cpuPercent),
                    ],
                  ),
                  (
                    label: 'agents',
                    color: kMakitAccent,
                    points: [
                      for (final s in window)
                        (ts: s.ts, value: metricsAgentsCpuPercent(s)),
                    ],
                  ),
                ],
                maxY: null,
                gridColor: cs.outlineVariant,
                gridAtY: 100,
              ),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: kSpace10),
          _Legend(
            items: [
              ('app', kBoardSwatch, formatCpu(latest.app?.cpuPercent)),
              ('server', kStatusWarning, formatCpu(latest.server.cpuPercent)),
              (
                'agents',
                kMakitAccent,
                formatCpu(metricsAgentsCpuPercent(latest)),
              ),
              ('sampler', cs.outline, formatCpu(latest.sampler.cpuPercent)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Resident memory, stacked. A parked agent keeps its runtime resident — that
/// plateau is the honest price of instant resume, and a staircase that never
/// comes down across turns is what a real leak looks like here.
class _MemoryCell extends StatelessWidget {
  const _MemoryCell({required this.window, required this.latest});

  final List<MetricsSample> window;
  final MetricsSample latest;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Cell(
      key: kDashboardMemoryCellKey,
      title: 'Memory — resident',
      caption: 'RSS · a parked agent still holds its runtime',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 110,
            child: CustomPaint(
              painter: StackedAreaPainter(
                series: [
                  (
                    label: 'app',
                    color: kBoardSwatch,
                    points: [
                      for (final s in window)
                        (ts: s.ts, value: _mb(s.app?.rssBytes)),
                    ],
                  ),
                  (
                    label: 'server',
                    color: kStatusWarning,
                    points: [
                      for (final s in window)
                        (ts: s.ts, value: _mb(s.server.rssBytes)),
                    ],
                  ),
                  (
                    label: 'agents',
                    color: kMakitAccent,
                    points: [
                      for (final s in window)
                        (ts: s.ts, value: _mb(metricsAgentsRssBytes(s))),
                    ],
                  ),
                ],
                maxY: null,
              ),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: kSpace10),
          _Legend(
            items: [
              (
                'app',
                kBoardSwatch,
                latest.app == null ? '—' : formatBytes(latest.app!.rssBytes),
              ),
              ('server', kStatusWarning, formatBytes(latest.server.rssBytes)),
              (
                'agents',
                kMakitAccent,
                formatBytes(metricsAgentsRssBytes(latest)),
              ),
              (
                'total',
                cs.outline,
                formatBytesOrDash(metricsKnownTotalRssBytes(latest)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Bytes as MB for plotting. Null stays null — a gap, not a zero.
  static double? _mb(int? bytes) =>
      bytes == null ? null : bytes / (1024 * 1024);
}

/// Frame-time distribution. Answers "did it feel smooth", which is the question
/// a UI is actually judged on — far more convincing than CPU%.
class _FrameCell extends StatelessWidget {
  const _FrameCell({required this.stats});

  final FrameStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final buckets = frameHistogram(stats);
    return _Cell(
      key: kDashboardFrameCellKey,
      title: 'Frame time — app',
      caption: '60 fps budget 16.7 ms',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: kSpace20,
            runSpacing: kSpace8,
            children: [
              _Big(
                value: stats.sampleCount == 0
                    ? '—'
                    : stats.p95Ms.toStringAsFixed(1),
                unit: 'p95 ms',
              ),
              _Big(value: '${stats.dropped}', unit: 'dropped'),
              _Big(value: '${stats.sampleCount}', unit: 'frames'),
            ],
          ),
          const SizedBox(height: kSpace12),
          SizedBox(
            height: 70,
            child: buckets.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No frames timed yet.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.outline,
                      ),
                    ),
                  )
                : CustomPaint(
                    painter: HistogramPainter(
                      buckets: buckets,
                      color: kMakitAccent,
                      overBudgetColor: kStatusWarning,
                      budgetBucket: kFrameBudgetBucket,
                    ),
                    size: Size.infinite,
                  ),
          ),
          const SizedBox(height: kSpace6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '0 ms',
                style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
              ),
              Text(
                '16.7 ms budget',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              Text(
                '50 ms+',
                style: theme.textTheme.labelSmall?.copyWith(color: cs.outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bucketed frame counts for the histogram, or empty when nothing was timed.
///
/// Exposed (not private) so a test can assert the bucketing without pumping a
/// widget: the boundary that matters — a frame exactly on the 16.7 ms budget —
/// is arithmetic, not layout.
List<int> frameHistogram(FrameStats stats) {
  if (stats.sampleCount == 0) return const [];
  final counts = List<int>.filled(kFrameBucketEdgesMs.length + 1, 0);
  for (final ms in stats.samplesMs) {
    var placed = false;
    for (var i = 0; i < kFrameBucketEdgesMs.length; i++) {
      if (ms <= kFrameBucketEdgesMs[i]) {
        counts[i]++;
        placed = true;
        break;
      }
    }
    if (!placed) counts[counts.length - 1]++;
  }
  return counts;
}

/// Event-loop latency + wire throughput. The loop percentile is the single best
/// server health metric: if it climbs, every device on the socket feels it.
class _ServerCell extends StatelessWidget {
  const _ServerCell({required this.window, required this.latest});

  final List<MetricsSample> window;
  final MetricsSample latest;

  @override
  Widget build(BuildContext context) {
    return _Cell(
      key: kDashboardServerCellKey,
      title: 'Server responsiveness',
      caption: 'event-loop delay · socket throughput',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: kSpace20,
            runSpacing: kSpace8,
            children: [
              _Big(
                value: latest.server.eventLoopP50.toStringAsFixed(1),
                unit: 'loop p50 ms',
              ),
              _Big(
                value: latest.server.eventLoopP99.toStringAsFixed(1),
                unit: 'loop p99 ms',
              ),
              _Big(
                value: (latest.wire.outBytesPerSec / 1024).toStringAsFixed(1),
                unit: 'wire KB/s',
              ),
            ],
          ),
          const SizedBox(height: kSpace12),
          SizedBox(
            height: 70,
            child: CustomPaint(
              painter: MultiLinePainter(
                series: [
                  (
                    label: 'p50',
                    color: kMakitAccent,
                    points: [
                      for (final s in window)
                        (ts: s.ts, value: s.server.eventLoopP50),
                    ],
                  ),
                  (
                    label: 'p99',
                    color: kStatusWarning,
                    points: [
                      for (final s in window)
                        (ts: s.ts, value: s.server.eventLoopP99),
                    ],
                  ),
                ],
                minPeak: 5,
              ),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }
}

/// Disk + socket footprint. Every number here is a thing a user can shrink:
/// prune old sessions, close a device, park an agent.
class _FootprintCell extends StatelessWidget {
  const _FootprintCell({required this.latest, required this.history});

  final MetricsSample latest;
  final List<MetricsSample> history;

  @override
  Widget build(BuildContext context) {
    final storage = metricsLatestStorage(history, latest);
    // `procs` is absent on coarse (background-cadence) frames. Counting a null as
    // exactly 1 turned an unknown into a precise-looking total, which is the same
    // fabrication decision 13 forbids for a failed `ps`. If any row is unknown the
    // sum is unknown.
    var procs = 0;
    var procsKnown = latest.procTableOk;
    for (final a in latest.agents) {
      final p = a.procs;
      if (p == null) {
        procsKnown = false;
      } else {
        procs += p;
      }
    }
    return _Cell(
      key: kDashboardFootprintCellKey,
      title: 'Footprint on disk & sockets',
      caption: 'steady state',
      child: Wrap(
        spacing: kSpace20,
        runSpacing: kSpace8,
        children: [
          _Big(
            value: storage == null
                ? '—'
                : (storage.eventLogBytes / (1024 * 1024)).toStringAsFixed(1),
            unit: 'event log MB',
          ),
          // With no readable process table we cannot say there are zero agents —
          // the sessions snapshot knows they exist, we just could not measure them.
          _Big(
            value: latest.procTableOk ? '${latest.agents.length}' : '—',
            unit: 'agents',
          ),
          _Big(value: procsKnown ? '$procs' : '—', unit: 'processes'),
          _Big(
            value: (latest.wire.framesPerSec).toStringAsFixed(1),
            unit: 'frames/s',
          ),
        ],
      ),
    );
  }
}

/// The process table. `CPU-s` is the optimisation target (see the library doc),
/// and `PID` is present so a user can cross-check every row against Activity
/// Monitor — if our number disagrees with theirs, ours is wrong.
class _ProcessTable extends StatelessWidget {
  const _ProcessTable({required this.latest});

  final MetricsSample latest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final rows = <_ProcRow>[
      if (latest.app case final app?)
        _ProcRow(
          name: 'makit (Flutter app)',
          pid: app.pid,
          rssBytes: app.rssBytes,
          cpuPercent: app.cpuPercent,
          cpuSeconds: app.cpuSeconds,
          procs: 1,
        ),
      _ProcRow(
        name: 'makit-server (Node)',
        pid: latest.server.pid,
        rssBytes: latest.server.rssBytes,
        cpuPercent: latest.server.cpuPercent,
        cpuSeconds: latest.server.cpuSeconds,
        procs: 1,
      ),
      for (final a in [
        ...latest.agents,
      ]..sort((x, y) => y.rssBytes.compareTo(x.rssBytes)))
        _ProcRow(
          name: a.label,
          pid: a.pid,
          rssBytes: a.rssBytes,
          cpuPercent: a.cpuPercent,
          cpuSeconds: a.cpuSeconds,
          procs: a.procs,
          uptimeMs: a.uptimeMs,
          inTurn: a.inTurn,
        ),
    ];

    return _Cell(
      key: kDashboardProcessTableKey,
      title: 'Processes',
      caption: 'tree totals · CPU-s is the column to optimise against',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!latest.procTableOk)
            Padding(
              padding: const EdgeInsets.only(bottom: kSpace10),
              child: Row(
                children: [
                  const Icon(
                    PhosphorIconsLight.warning,
                    size: 14,
                    color: kStatusWarning,
                  ),
                  const SizedBox(width: kSpace8),
                  Expanded(
                    child: Text(
                      'The process table could not be read — app and agent rows '
                      'are unknown for this sample, not zero.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: kStatusWarning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const _ProcHeaderRow(),
          Divider(color: cs.outlineVariant, height: kSpace12),
          for (final r in rows) _ProcTableRow(row: r),
          Divider(color: cs.outlineVariant, height: kSpace12),
          _ProcTotalRow(latest: latest),
        ],
      ),
    );
  }
}

class _ProcRow {
  const _ProcRow({
    required this.name,
    required this.pid,
    required this.rssBytes,
    required this.cpuPercent,
    required this.cpuSeconds,
    this.procs,
    this.uptimeMs,
    this.inTurn = false,
  });

  final String name;
  final int pid;
  final int rssBytes;
  final double? cpuPercent;
  final double cpuSeconds;
  final int? procs;
  final int? uptimeMs;
  final bool inTurn;
}

const List<int> _colFlex = [4, 2, 2, 2, 2, 2, 2];
const List<String> _colLabels = [
  'Process',
  'PID',
  'RSS',
  'CPU',
  'CPU-s',
  'Uptime',
  'Procs',
];

class _ProcHeaderRow extends StatelessWidget {
  const _ProcHeaderRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
    );
    return Row(
      children: [
        for (var i = 0; i < _colLabels.length; i++)
          Expanded(
            flex: _colFlex[i],
            child: Text(
              _colLabels[i],
              textAlign: i == 0 ? TextAlign.left : TextAlign.right,
              style: style,
            ),
          ),
      ],
    );
  }
}

class _ProcTableRow extends StatelessWidget {
  const _ProcTableRow({required this.row});

  final _ProcRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: kMonoFontFamily,
    );
    final cells = <String>[
      row.name,
      '${row.pid}',
      formatBytes(row.rssBytes),
      formatCpu(row.cpuPercent),
      row.cpuSeconds.toStringAsFixed(1),
      row.uptimeMs == null ? '—' : formatDuration(row.uptimeMs!),
      row.procs == null ? '—' : '${row.procs}',
    ];
    return Semantics(
      label:
          '${row.name}, pid ${row.pid}, ${formatBytes(row.rssBytes)} resident, '
          '${formatCpu(row.cpuPercent)} CPU, '
          '${row.cpuSeconds.toStringAsFixed(1)} CPU seconds',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: kSpace4),
        child: Row(
          children: [
            for (var i = 0; i < cells.length; i++)
              Expanded(
                flex: _colFlex[i],
                child: Text(
                  cells[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                  style: i == 0
                      ? theme.textTheme.bodySmall?.copyWith(
                          color: row.inTurn ? cs.onSurface : null,
                          fontWeight: row.inTurn ? FontWeight.w600 : null,
                        )
                      : mono,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProcTotalRow extends StatelessWidget {
  const _ProcTotalRow({required this.latest});

  final MetricsSample latest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var cpuSeconds = latest.server.cpuSeconds + (latest.app?.cpuSeconds ?? 0);
    var procs = 1 + (latest.app == null ? 0 : 1);
    // A total is only a total if every part was measured. With no process table
    // the app and agent rows are missing, so summing what is left would present
    // the SERVER's numbers under a "makit total" label — precisely the reading
    // decision 13 exists to prevent.
    var known = latest.procTableOk;
    for (final a in latest.agents) {
      cpuSeconds += a.cpuSeconds;
      final p = a.procs;
      if (p == null) {
        known = false;
      } else {
        procs += p;
      }
    }
    final cells = <String>[
      known ? 'makit total' : 'makit total (incomplete)',
      '',
      known ? formatBytes(metricsTotalRssBytes(latest)) : '—',
      known ? formatCpu(metricsTotalCpuPercent(latest)) : '—',
      known ? cpuSeconds.toStringAsFixed(1) : '—',
      '',
      known ? '$procs' : '—',
    ];
    final style = theme.textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w600,
      fontFamily: kMonoFontFamily,
    );
    return Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: _colFlex[i],
            child: Text(
              cells[i],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: i == 0 ? TextAlign.left : TextAlign.right,
              style: style,
            ),
          ),
      ],
    );
  }
}

/// The footer: our own cost, plus export. Export is the **only** path from a
/// sample to disk, and only when the user asks (decision 5).
class _Footer extends ConsumerWidget {
  const _Footer({
    required this.latest,
    required this.history,
    required this.baseline,
    required this.onSetBaseline,
  });

  final MetricsSample? latest;
  final List<MetricsSample> history;
  final MetricsSample? baseline;
  final VoidCallback? onSetBaseline;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sampler = latest?.sampler;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace20,
        vertical: kSpace12,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              sampler == null
                  ? 'Measuring costs nothing while this panel is closed.'
                  : 'Measuring costs ${formatCpu(sampler.cpuPercent)} CPU while '
                        'this panel is open. Closing it returns the collector to '
                        'one coarse sample every 5 s.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: kSpace12),
          OutlinedButton(
            key: kDashboardBaselineKey,
            onPressed: onSetBaseline,
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: cs.outlineVariant),
              foregroundColor: cs.onSurfaceVariant,
            ),
            child: Text(baseline == null ? 'Set baseline' : 'Baseline set'),
          ),
          const SizedBox(width: kSpace8),
          OutlinedButton.icon(
            key: kDashboardExportKey,
            onPressed: history.isEmpty ? null : () => _copyExport(ref, history),
            icon: const Icon(PhosphorIconsLight.download, size: 14),
            label: const Text('Export snapshot'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: cs.outlineVariant),
              foregroundColor: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Exports **both** halves of the artifact, because they answer different
  /// questions: the markdown summary goes to the clipboard (the form a perf claim
  /// travels in — a PR comment, an issue), and the full ring plus any stored
  /// baseline is written to disk as round-trippable JSON.
  ///
  /// Copying markdown alone was a real defect: the headline numbers left the app
  /// but the samples behind them could not, so nobody could re-examine or diff
  /// them. This is still the only path from a sample to disk, and only on an
  /// explicit click (decision 5).
  Future<void> _copyExport(WidgetRef ref, List<MetricsSample> history) async {
    // Resolved before the first await: `ref` throws once its widget is
    // unmounted, and the record must survive the thing that reported to it.
    final status = ref.status;
    final md = metricsExportMarkdown(
      history: history,
      appVersion: 'makit',
      platform: defaultTargetPlatform.name,
      baseline: baseline,
    );
    // The two halves are independent and must fail independently: a clipboard
    // that refuses (no platform handler, a locked pasteboard) must not cost the
    // user the JSON artifact, and vice versa.
    //
    // The file is written FIRST and deliberately: it is the half that cannot be
    // reconstructed later (the ring is bounded and moves on), whereas the
    // markdown can be regenerated by pressing the button again. Sequencing it
    // behind an await on a platform channel would make the irreplaceable half
    // depend on the reproducible one.
    final json = metricsExportJsonString(
      history: history,
      appVersion: 'makit',
      platform: defaultTargetPlatform.name,
      baseline: baseline,
    );
    String? path;
    try {
      path = await ref.read(metricsSnapshotWriterProvider)(
        metricsSnapshotFilename(DateTime.now()),
        json,
      );
    } catch (_) {
      path = null;
    }

    var copied = true;
    try {
      await Clipboard.setData(ClipboardData(text: md));
    } catch (_) {
      copied = false;
    }
    if (copied && path != null) {
      status.success(
        'Copied metrics markdown and wrote the JSON snapshot',
        source: StatusSources.metrics,
        detail: path,
      );
    } else if (copied) {
      status.warning(
        'Copied metrics markdown, but could not write the JSON snapshot',
        source: StatusSources.metrics,
      );
    } else if (path != null) {
      status.warning(
        'Wrote the JSON snapshot, but could not copy to the clipboard',
        source: StatusSources.metrics,
        detail: path,
      );
    } else {
      status.failure(
        'Export failed — neither the clipboard nor the file was written',
        source: StatusSources.metrics,
      );
    }
  }
}

class _Big extends StatelessWidget {
  const _Big({required this.value, required this.unit});

  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
        const SizedBox(height: kSpace2),
        Text(
          unit,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.items});

  final List<(String, Color, String)> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: kSpace12,
      runSpacing: kSpace6,
      children: [
        for (final (label, color, value) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: kSpace6),
              Text(
                '$label ',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(value, style: theme.textTheme.labelSmall),
            ],
          ),
      ],
    );
  }
}
