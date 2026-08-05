/// SPEC-37 Tier 1 — the desktop sidebar footer's resource-use indicator.
///
/// A single pulse [IconButton] that answers *"what is makit costing me right
/// now?"* in one click, and opens the dashboard in two. Structural clone of
/// [GithubBudgetButton]: same anchored-and-clamped [OverlayPortal], same
/// gesture/`Esc` dismissal, same footer metrics.
///
/// Two properties of this panel are load-bearing and easy to lose in a refactor:
///
/// * It **acquires the 1 Hz watch only while open** (via the ref-counted
///   [metricsWatchControllerProvider]) and releases it on dismiss. A panel that
///   leaked its watch would pin the sampler at 1 Hz forever — in the feature
///   whose entire claim is that makit is cheap when nobody is looking.
/// * A failed process-table read renders **"measurement unavailable"**, never
///   zeros and never an empty machine (decision 13). Zeros read as "idle" and a
///   missing row reads as "exited"; both are lies, and the second is exactly how
///   SPEC-32's PR pills used to vanish under rate limits.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/metrics.dart';
import '../../store/prefs/preference_entries.dart';
import '../../store/prefs/preferences_providers.dart';
import 'charts.dart';
import 'frame_timings.dart';
import '../window_overlays.dart';
import 'metrics_icon_state.dart';

/// Test hooks: stable keys so widget tests assert structure, not copy.
const Key kMetricsPopoverKey = ValueKey('metrics-popover');
const Key kMetricsHeadlineKey = ValueKey('metrics-headline');
const Key kMetricsUnavailableKey = ValueKey('metrics-unavailable');
const Key kMetricsHistoryPillKey = ValueKey('metrics-history-pill');
const Key kMetricsOpenDashboardKey = ValueKey('metrics-open-dashboard');
const Key kMetricsAgentListKey = ValueKey('metrics-agent-list');
const Key kMetricsSelfCostKey = ValueKey('metrics-self-cost');

/// Fixed popover width; the overlay math needs it up front (see
/// [GithubBudgetButton] for why clamping is load-bearing at this anchor).
const double kMetricsPopoverWidth = 300;

/// Minimum breathing room between the popover and the window edges.
const double kMetricsPopoverMargin = kSpace8;

/// Floor for the popover's height cap, so a short window still shows a usable
/// scrollable panel rather than a sliver.
const double _kMinPopoverHeight = 140;

/// Window of history the popover's sparklines and History expander show.
const int kMetricsPopoverWindowMs = 5 * 60 * 1000;

/// The footer resource-use button plus its click-to-open popover.
class MetricsButton extends ConsumerStatefulWidget {
  /// Creates the button.
  const MetricsButton({super.key});

  @override
  ConsumerState<MetricsButton> createState() => _MetricsButtonState();
}

class _MetricsButtonState extends ConsumerState<MetricsButton>
    with SingleTickerProviderStateMixin {
  final _anchorKey = GlobalKey();
  final _controller = OverlayPortalController();
  bool _open = false;

  /// Drives the Working state's glyph animation. Decision 12: working is shown
  /// by *motion*, not by a tint — an always-on "busy" colour would be lit all
  /// day and mean nothing.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  /// Held while the popover is open so the sampler runs at 1 Hz; released on
  /// dismiss and on dispose (a dispose while open must not leak the watch).
  ///
  /// The controller is **cached** rather than re-read on release: `ref` is unsafe
  /// once the element is unmounting, so reading it from [dispose] would throw and
  /// the watch would leak exactly in the teardown path that most needs it.
  MetricsWatchController? _held;

  /// Cached for the same reason as [_held]: `dispose` cannot read `ref`.
  FrameTimingsCollector? _frames;

  void _acquireWatch() {
    if (_held != null) return;
    final controller = ref.read(metricsWatchControllerProvider);
    _held = controller;
    controller.watch();
    // Frame timings cost a callback on every frame, so they are collected only
    // while somebody is looking — the same rule as the 1 Hz cadence itself.
    final frames = ref.read(frameTimingsProvider);
    _frames = frames;
    frames.register();
  }

  void _releaseWatch() {
    final controller = _held;
    final frames = _frames;
    _held = null;
    _frames = null;
    controller?.release();
    // A leaked addTimingsCallback runs for the process lifetime, which is a
    // permanent cost in the feature that claims makit is cheap.
    frames?.dispose();
  }

  void _toggle() {
    setState(() {
      if (_open) {
        _controller.hide();
        _releaseWatch();
      } else {
        _controller.show();
        _acquireWatch();
      }
      _open = !_open;
    });
  }

  void _close() {
    if (!_open) return;
    setState(() {
      _controller.hide();
      _releaseWatch();
      _open = false;
    });
  }

  @override
  void dispose() {
    // Order matters only in that both must happen: the watch is ref-counted
    // server state, the ticker is local.
    _releaseWatch();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sample = ref.watch(metricsProvider);
    final history = ref.watch(metricsHistoryProvider);
    final cs = Theme.of(context).colorScheme;

    final state = metricsIconState(
      sample,
      elevatedSinceMs: metricsElevatedSinceMs(history),
      nowMs: sample?.ts ?? 0,
    );
    final color = metricsIconColor(state, cs);

    // Animate only while a turn runs; a ticker that kept running while parked
    // would itself be idle cost in the panel that measures idle cost.
    if (state == MetricsIconState.working) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else if (_pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }

    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (ctx) => _overlay(ctx),
      child: KeyedSubtree(
        key: _anchorKey,
        child: IconButton(
          tooltip: metricsTooltip(sample, state),
          onPressed: _toggle,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          style: _open
              ? IconButton.styleFrom(
                  backgroundColor: cs.onSurface.withValues(alpha: 0.11),
                )
              : null,
          icon: FadeTransition(
            // 1.0 → 0.45 while working, constant 1.0 otherwise.
            opacity: _pulse.drive(Tween(begin: 1, end: 0.45)),
            child: Icon(PhosphorIconsLight.pulse, size: 18, color: color),
          ),
        ),
      ),
    );
  }

  /// Anchors the popover above the icon, right-aligned, then clamps it into the
  /// window on both axes — see [GithubBudgetButton] for why that clamp is not
  /// merely defensive at this anchor position.
  Widget _overlay(BuildContext context) {
    final anchor = _anchorKey.currentContext?.findRenderObject();
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (anchor is! RenderBox || overlayBox is! RenderBox || !anchor.hasSize) {
      return const SizedBox.shrink();
    }
    final overlaySize = overlayBox.size;
    final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlayBox);

    final preferredLeft = topLeft.dx + anchor.size.width - kMetricsPopoverWidth;
    final maxLeft =
        overlaySize.width - kMetricsPopoverWidth - kMetricsPopoverMargin;
    final left = maxLeft <= kMetricsPopoverMargin
        ? kMetricsPopoverMargin
        : preferredLeft.clamp(kMetricsPopoverMargin, maxLeft);

    final bottom = overlaySize.height - topLeft.dy + kSpace6;
    final maxHeight = math.max(
      _kMinPopoverHeight,
      topLeft.dy - kSpace6 - kMetricsPopoverMargin,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _close,
          ),
        ),
        Positioned(
          left: left,
          bottom: bottom,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _close,
            },
            child: Focus(
              autofocus: true,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: MetricsPopover(onClose: _close),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One-line hover tooltip, in the same register as the sibling footer buttons.
String metricsTooltip(MetricsSample? sample, MetricsIconState state) {
  if (sample == null) return 'Resource use — not measured yet';
  if (!sample.procTableOk) {
    return 'Resource use — measurement unavailable (process table unreadable)';
  }
  final cpu = metricsTotalCpuPercent(sample);
  final head =
      '${formatBytes(metricsTotalRssBytes(sample))} total · ${formatCpu(cpu)} CPU';
  return switch (state) {
    MetricsIconState.off => 'Resource use — not measured yet',
    MetricsIconState.idle => 'Resource use — idle · $head',
    MetricsIconState.working => 'Resource use — turn running · $head',
    MetricsIconState.elevated =>
      'Resource use — elevated while idle · $head · click for detail',
    MetricsIconState.pressure =>
      'Resource use — under pressure · $head · click for detail',
  };
}

/// Total resident bytes across every measured surface.
int metricsTotalRssBytes(MetricsSample s) {
  var total = (s.app?.rssBytes ?? 0) + s.server.rssBytes;
  for (final agent in s.agents) {
    total += agent.rssBytes;
  }
  return total;
}

/// Sum of the agents' resident bytes.
int metricsAgentsRssBytes(MetricsSample s) {
  var total = 0;
  for (final agent in s.agents) {
    total += agent.rssBytes;
  }
  return total;
}

/// Sum of the agents' CPU%, or null when no agent has a computable rate.
double? metricsAgentsCpuPercent(MetricsSample s) {
  double? total;
  for (final agent in s.agents) {
    final cpu = agent.cpuPercent;
    if (cpu == null) continue;
    total = (total ?? 0) + cpu;
  }
  return total;
}

// ─────────────────────────────── popover ──────────────────────────────────

/// The anchored popover. Collapsed by default; the History pill expands in
/// place, and that flag persists via [metricsHistoryExpandedPreference].
class MetricsPopover extends ConsumerWidget {
  /// Creates the popover.
  const MetricsPopover({super.key, this.onClose});

  /// Dismisses the popover — used by `Open dashboard →`, which replaces this
  /// panel with the Tier 2 overlay rather than stacking on top of it.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final sample = ref.watch(metricsProvider);
    final history = ref.watch(metricsHistoryProvider);
    final expanded = ref.preference(metricsHistoryExpandedPreference);

    return Material(
      key: kMetricsPopoverKey,
      color: cs.surfaceContainerLow,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(kRadius12),
      child: Container(
        width: kMetricsPopoverWidth,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius12),
          border: Border.all(color: cs.outlineVariant),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace12,
          vertical: kSpace12,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Header(),
              const SizedBox(height: kSpace10),
              if (sample == null)
                const _NoSampleBody()
              else if (!sample.procTableOk)
                _UnavailableBody(sample: sample)
              else
                ..._measuredBody(context, ref, sample, history),
              const SizedBox(height: kSpace12),
              _PillRow(
                expanded: expanded,
                onToggle: () => ref
                    .read(preferencesControllerProvider.notifier)
                    .set(metricsHistoryExpandedPreference, !expanded),
                onOpenDashboard: () {
                  ref.read(metricsDashboardOpenProvider.notifier).state = true;
                  onClose?.call();
                },
              ),
              if (expanded && sample != null)
                _HistoryDetail(sample: sample, history: history),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _measuredBody(
    BuildContext context,
    WidgetRef ref,
    MetricsSample sample,
    List<MetricsSample> history,
  ) {
    final window = metricsWindow(history, sample.ts, kMetricsPopoverWindowMs);
    // Memory-sorted: the biggest consumer is the one worth acting on, and RSS is
    // the stable ordering key (CPU% flips between ticks and would reshuffle the
    // list under the reader's cursor).
    final agents = [...sample.agents]
      ..sort((a, b) => b.rssBytes.compareTo(a.rssBytes));

    return [
      _Headline(sample: sample),
      const SizedBox(height: kSpace4),
      _StatusLine(sample: sample),
      const SizedBox(height: kSpace8),
      _SurfaceRow(
        label: 'App (Flutter)',
        tip:
            'The Flutter desktop app: its own resident size, with CPU sampled '
            'by the server on the same machine — one collector, no platform '
            'channel.',
        rssBytes: sample.app?.rssBytes,
        cpuPercent: sample.app?.cpuPercent,
        points: window
            .map((s) => (ts: s.ts, value: s.app?.cpuPercent))
            .toList(),
        color: kBoardSwatch,
      ),
      _SurfaceRow(
        label: 'Server (Node)',
        tip:
            'The Node server, read from process.memoryUsage().rss and '
            'process.cpuUsage() deltas — exact, with no ps needed for self.',
        rssBytes: sample.server.rssBytes,
        cpuPercent: sample.server.cpuPercent,
        points: window
            .map((s) => (ts: s.ts, value: s.server.cpuPercent))
            .toList(),
        color: kStatusWarning,
      ),
      _SurfaceRow(
        label: 'Agents (${sample.agents.length})',
        tip:
            'Whole process trees, not just the direct child: an agent spawns '
            'bash, ripgrep and language servers, and attributing only the child '
            'can understate the real cost several-fold. A parked agent still '
            'holds its runtime resident — that is the honest price of instant '
            'resume.',
        rssBytes: metricsAgentsRssBytes(sample),
        cpuPercent: metricsAgentsCpuPercent(sample),
        points: window
            .map((s) => (ts: s.ts, value: metricsAgentsCpuPercentOf(s)))
            .toList(),
        color: kMakitAccent,
      ),
      if (agents.isNotEmpty) ...[
        const SizedBox(height: kSpace10),
        const _SectionLabel('PER AGENT'),
        const SizedBox(height: kSpace4),
        Column(
          key: kMetricsAgentListKey,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final a in agents) _AgentRow(agent: a)],
        ),
      ],
    ];
  }
}

/// [metricsAgentsCpuPercent] as a free function, for mapping over history.
double? metricsAgentsCpuPercentOf(MetricsSample s) =>
    metricsAgentsCpuPercent(s);

/// The most recent measured event-log size: [latest]'s own figure, else the
/// newest non-null one in [history]. Null only when storage was never measured
/// — which is not zero bytes, so the caller omits the row rather than printing
/// a size nobody measured.
StorageMetrics? metricsLatestStorage(
  List<MetricsSample> history,
  MetricsSample latest,
) {
  if (latest.storage case final s?) return s;
  for (var i = history.length - 1; i >= 0; i--) {
    if (history[i].storage case final s?) return s;
  }
  return null;
}

/// The tail of [history] within [windowMs] of [nowMs]. Time-based, not a fixed
/// count, because the ring mixes 1 Hz and 5 s samples.
List<MetricsSample> metricsWindow(
  List<MetricsSample> history,
  int nowMs,
  int windowMs,
) {
  final cutoff = nowMs - windowMs;
  return history.where((s) => s.ts >= cutoff).toList();
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        Icon(PhosphorIconsLight.pulse, size: 14, color: cs.onSurfaceVariant),
        const SizedBox(width: kSpace8),
        Expanded(
          child: _Explain(
            message:
                'What makit costs right now, split by surface and attributable '
                'to a process id you can cross-check in Activity Monitor.',
            child: Text(
              'Resource use',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        _Explain(
          message:
              'While this panel is open the server samples once a second. '
              'Closing it drops back to one reading every 5 seconds — the panel '
              'must not become the cost it reports.',
          child: Text(
            '1 Hz · live',
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// Before the first sample: an honest `—`, never a zeroed skeleton.
class _NoSampleBody extends StatelessWidget {
  const _NoSampleBody();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '—',
          key: kMetricsHeadlineKey,
          style: theme.textTheme.headlineMedium?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: kSpace6),
        Text(
          'No reading yet. The first sample lands within a second of opening '
          'this panel; if background sampling is off, its history starts here.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// `procTableOk == false`: the `ps` read failed, so there is nothing honest to
/// say about the app or the agents (decision 13). The **server** row survives —
/// it comes from `process.memoryUsage()`, not from `ps` — so it is still shown,
/// which is also what proves this state is a measurement failure and not an
/// empty machine.
class _UnavailableBody extends StatelessWidget {
  const _UnavailableBody({required this.sample});

  final MetricsSample sample;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: kMetricsUnavailableKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Explain(
          message:
              'The process-table read (ps) failed, so per-process numbers are '
              'unknown. They are omitted rather than zeroed: a row of zeros '
              'would read as "idle" and a missing row as "exited", and both '
              'would be false.',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                PhosphorIconsLight.warning,
                size: 14,
                color: kStatusWarning,
              ),
              const SizedBox(width: kSpace8),
              Expanded(
                child: Text(
                  'Measurement unavailable — the process table could not be '
                  'read, so app and agent numbers are unknown (not zero).',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: kStatusWarning,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: kSpace10),
        _SurfaceRow(
          label: 'Server (Node)',
          tip: 'Still valid: the server measures itself directly, without ps.',
          rssBytes: sample.server.rssBytes,
          cpuPercent: sample.server.cpuPercent,
          points: const [],
          color: kStatusWarning,
        ),
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.sample});

  final MetricsSample sample;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (value, unit) = splitBytes(metricsTotalRssBytes(sample));
    return _Explain(
      message:
          'Every surface added up: the app, the server, and every agent process '
          'tree. The number to compare against your editor and terminals.',
      child: Row(
        key: kMetricsHeadlineKey,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            value,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          ),
          const SizedBox(width: kSpace6),
          // Flexible: the caption carries two numbers and a unit, and at a large
          // text scale it is wider than the 300pt panel. It is the part that may
          // safely wrap — the headline figure must never shrink.
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '$unit total · ${formatCpu(metricsTotalCpuPercent(sample))} CPU',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "idle — no turn running · 2 agents parked" / "1 turn running — <label>".
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.sample});

  final MetricsSample sample;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final working = sample.agents.where((a) => a.inTurn).toList();
    final parked = sample.agents.length - working.length;
    final String text;
    // `turnActive` — not the agent rows — decides whether a turn is open. The
    // collector omits sessions with no pid (decision 11) but still reports
    // turnActive for them, so deriving this from `agents` alone printed "idle"
    // while the footer glyph animated as Working: one panel making two
    // contradictory claims. The rows only decide how specific the copy can be.
    if (!sample.turnActive) {
      text = parked == 0
          ? 'idle — no agents running'
          : 'idle — no turn running · '
                '$parked agent${parked == 1 ? '' : 's'} parked';
    } else if (working.isEmpty) {
      // A turn is open in a session we cannot measure (no pid: a stub adapter,
      // or a spawn whose pid we never saw). Say exactly that instead of naming
      // a session we have no numbers for.
      text = 'turn running — not attributable to a measured process';
    } else {
      final names = working.map((a) => a.label).join(', ');
      text =
          '${working.length} turn${working.length == 1 ? '' : 's'} '
          'running — $names';
    }
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
    );
  }
}

/// One surface row: label, resident size, CPU%, and a 5-minute sparkline.
///
/// Carries a [Semantics] label with its numbers so the row is legible to a
/// screen reader, which a bare `Row` of three `Text`s plus a `CustomPaint` is
/// not (spec § Testing, A11y).
class _SurfaceRow extends StatelessWidget {
  const _SurfaceRow({
    required this.label,
    required this.tip,
    required this.rssBytes,
    required this.cpuPercent,
    required this.points,
    required this.color,
  });

  final String label;
  final String tip;

  /// Null when the surface is not measurable (no loopback pid, or `ps` failed) —
  /// rendered `—`, never 0.
  final int? rssBytes;
  final double? cpuPercent;
  final List<MetricPoint> points;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final rss = rssBytes;
    final rssText = rss == null ? '—' : formatBytes(rss);
    final cpuText = formatCpu(cpuPercent);
    return Semantics(
      label: '$label, $rssText resident, $cpuText CPU',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: kSpace8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: _Explain(
                message: tip,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ),
            if (points.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: kSpace8),
                child: SizedBox(
                  width: 48,
                  height: 14,
                  child: CustomPaint(
                    painter: MetricSparklinePainter(
                      points: points,
                      color: color.withValues(alpha: 0.9),
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            Text(rssText, style: small),
            const SizedBox(width: kSpace8),
            SizedBox(
              width: 40,
              child: Text(
                cpuText,
                textAlign: TextAlign.right,
                style: small?.copyWith(fontFamily: kMonoFontFamily),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One agent, two lines: `pi · makit` over `up 12m · 1 proc`.
///
/// The mockup reads "parked 12m"/"turn 00:41", but the sample carries neither a
/// park duration nor a turn start — only process `uptimeMs`. Labelling uptime as
/// a park clock would be a fabrication in the panel whose whole claim is
/// honesty, so the second line states what is actually measured and the turn is
/// reported without a stopwatch.
class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.agent});

  final AgentMetrics agent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final small = theme.textTheme.bodySmall;

    // procs/uptimeMs are absent on coarse background frames, so each part is
    // omitted rather than printed as "0 procs" / "up 0s".
    final parts = <String>[
      if (agent.inTurn) 'in turn' else 'parked',
      if (agent.uptimeMs case final ms?) 'up ${formatDuration(ms)}',
      if (agent.procs case final n?) '$n proc${n == 1 ? '' : 's'}',
    ];
    final detail = parts.join(' · ');
    final rssText = formatBytes(agent.rssBytes);
    final cpuText = formatCpu(agent.cpuPercent);

    return Semantics(
      label: '${agent.label}, $detail, $rssText resident, $cpuText CPU',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: kSpace6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: agent.inTurn ? kMakitAccent : cs.outlineVariant,
                ),
              ),
            ),
            const SizedBox(width: kSpace8),
            // Expanded so a long session label ellipsises instead of overflowing
            // the fixed 300pt popover (asserted in the widget tests).
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    agent.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: kSpace8),
            Text(rssText, style: small),
            const SizedBox(width: kSpace8),
            SizedBox(
              width: 40,
              child: Text(
                cpuText,
                textAlign: TextAlign.right,
                style: small?.copyWith(fontFamily: kMonoFontFamily),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.9,
      ),
    );
  }
}

/// The History expander pill and `Open dashboard →`.
class _PillRow extends StatelessWidget {
  const _PillRow({
    required this.expanded,
    required this.onToggle,
    required this.onOpenDashboard,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onOpenDashboard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        _Explain(
          message:
              'Show the last five minutes: stacked CPU by surface, UI frame '
              'times, server event-loop latency, socket traffic — and this '
              "panel's own cost.",
          child: InkWell(
            key: kMetricsHistoryPillKey,
            borderRadius: BorderRadius.circular(999),
            onTap: onToggle,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: kSpace10,
                vertical: kSpace4,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: expanded ? cs.outline : cs.outlineVariant,
                ),
                color: expanded
                    ? cs.onSurface.withValues(alpha: 0.06)
                    : Colors.transparent,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    PhosphorIconsLight.chartLine,
                    size: 12,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: kSpace6),
                  Text(
                    'History',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: expanded ? cs.onSurface : cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: kSpace6),
                  Icon(
                    expanded
                        ? PhosphorIconsLight.caretUp
                        : PhosphorIconsLight.caretDown,
                    size: 11,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _Explain(
              message:
                  'The full dashboard: per-surface charts, the process table, '
                  'and snapshot export.',
              child: InkWell(
                key: kMetricsOpenDashboardKey,
                borderRadius: BorderRadius.circular(kSpace6),
                onTap: onOpenDashboard,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: kSpace6,
                    vertical: kSpace2,
                  ),
                  child: Text(
                    'Open dashboard →',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The expanded detail: stacked 5-minute CPU, responsiveness, wire, and — the
/// point of decision 10 — this panel's own cost, so the claim is falsifiable by
/// the reader rather than asserted by us.
class _HistoryDetail extends ConsumerWidget {
  const _HistoryDetail({required this.sample, required this.history});

  final MetricsSample sample;
  final List<MetricsSample> history;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final window = metricsWindow(history, sample.ts, kMetricsPopoverWindowMs);
    final totals = window
        .map((s) => (ts: s.ts, value: metricsTotalCpuPercent(s)))
        .toList();
    final hasSeries = metricPeak(totals) != null;

    return Container(
      margin: const EdgeInsets.only(top: kSpace12),
      padding: const EdgeInsets.only(top: kSpace12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('LAST 5 MINUTES · CPU'),
          const SizedBox(height: kSpace8),
          SizedBox(
            height: 40,
            child: hasSeries
                ? CustomPaint(
                    painter: MetricSparklinePainter(
                      points: totals,
                      color: kMakitAccent,
                      minPeak: 5,
                    ),
                    size: Size.infinite,
                  )
                // An empty frame reads as a rendering failure; say why instead.
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No rate computable yet — a rate needs two samples.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.outline,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: kSpace10),
          const _SectionLabel('RESPONSIVENESS'),
          _StatRow(
            label: 'Frame p95',
            tip:
                'How long the UI took to build and raster its slowest frames, '
                'from SchedulerBinding.addTimingsCallback. Under 16.7 ms means '
                'the UI held 60 fps even while an agent burned a core — the '
                'claim this panel exists to check.',
            value: formatFrameStats(ref.read(frameTimingsProvider).stats),
          ),
          _StatRow(
            label: 'Event-loop p99',
            tip:
                'From the server\'s monitorEventLoopDelay. The single best '
                'server health metric: if it climbs, every device on the socket '
                'feels it.',
            value: '${sample.server.eventLoopP99.toStringAsFixed(1)} ms',
          ),
          _StatRow(
            label: 'Socket traffic',
            tip:
                'Bytes per second in and out of this websocket, so a chatty '
                'protocol change shows up as traffic rather than as mystery CPU.',
            value:
                '${formatBytes(sample.wire.inBytesPerSec.round())}/s in · '
                '${formatBytes(sample.wire.outBytesPerSec.round())}/s out',
          ),
          // Storage refreshes every 6th tick, so the latest sample is usually
          // null; the last measurement stays true until a newer one lands.
          if (metricsLatestStorage(history, sample) case final storage?)
            _StatRow(
              label: 'Event log',
              tip:
                  'Total size of the append-only session logs on disk. No '
                  'metrics sample is ever written there (decision 5).',
              value: formatBytes(storage.eventLogBytes),
            ),
          const SizedBox(height: kSpace8),
          // Decision 10: the panel displays its own cost. This row is the whole
          // argument — a meter that hid its own overhead would be worthless.
          _StatRow(
            key: kMetricsSelfCostKey,
            label: 'This panel',
            tip:
                'What the measurement itself costs: the CPU one sampling tick '
                'burns, over the interval between ticks. If this is not '
                'negligible, the feature contradicts the claim it exists to '
                'prove — so it is shown, not hidden. Resident size reads "—" '
                'because the sampler runs inside the server process above and '
                'its share of that memory is not separately attributable.',
            value:
                '${formatCpu(sample.sampler.cpuPercent)} CPU · '
                '${formatBytesOrDash(sample.sampler.rssBytes)}',
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    super.key,
    required this.label,
    required this.tip,
    required this.value,
  });

  final String label;
  final String tip;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    return Semantics(
      label: '$label, $value',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: kSpace6),
        child: Row(
          children: [
            Expanded(
              child: _Explain(
                message: tip,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(width: kSpace8),
            // Flexible for the same reason as the headline caption: the socket
            // row's value is the longest string in the panel.
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: small?.copyWith(fontFamily: kMonoFontFamily),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The shared explainer tooltip, matching [GithubBudgetButton]'s register: it
/// explains *why the number matters*, not what it is called.
class _Explain extends StatelessWidget {
  const _Explain({required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      waitDuration: const Duration(milliseconds: 600),
      preferBelow: false,
      child: child,
    );
  }
}

// ─────────────────────────────── helpers ──────────────────────────────────

/// Frame p95 plus a dropped count, or `—` when no frame has been timed yet.
///
/// An untimed ring must not read `0.0 ms`: no measurement is not a fast frame,
/// and this row's whole purpose is to be checkable.
String formatFrameStats(FrameStats stats) {
  if (stats.sampleCount == 0) return '—';
  final p95 = '${stats.p95Ms.toStringAsFixed(1)} ms';
  return stats.dropped == 0 ? p95 : '$p95 · ${stats.dropped} dropped';
}

/// CPU% for display: `—` when no rate is computable yet (decision 2 — never
/// coerce a null rate to `0.0%`, which reads as a measured idle).
String formatCpu(double? percent) =>
    percent == null ? '—' : '${percent.toStringAsFixed(1)}%';

/// Resident bytes split into value and unit, e.g. `(1.22, 'GB')`.
(String, String) splitBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) {
    return ((bytes / gb).toStringAsFixed(2), 'GB');
  }
  if (bytes >= mb) {
    return ((bytes / mb).round().toString(), 'MB');
  }
  if (bytes >= kb) {
    return ((bytes / kb).round().toString(), 'kB');
  }
  return (bytes.toString(), 'B');
}

/// [formatBytes], or `—` when the figure is unknown. Distinct from passing 0:
/// "not separately attributable" and "measured as zero" are different claims,
/// and only one of them is true of the sampler's resident size.
String formatBytesOrDash(int? bytes) =>
    bytes == null ? '—' : formatBytes(bytes);

/// Resident bytes as a single string, e.g. `118 MB` / `1.22 GB`.
String formatBytes(int bytes) {
  final (value, unit) = splitBytes(bytes);
  return '$value $unit';
}

/// Coarse duration for the agent detail line: `45s`, `12m`, `3h 04m`.
String formatDuration(int ms) {
  final totalSeconds = ms ~/ 1000;
  if (totalSeconds < 60) return '${totalSeconds}s';
  final minutes = totalSeconds ~/ 60;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  return '${hours}h ${(minutes % 60).toString().padLeft(2, '0')}m';
}
