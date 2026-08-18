import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../store/turns.dart';
import '../session/elapsed.dart';

// ─── formatting (pure, unit-tested) ──────────────────────────────────────────

/// Abbreviated token count: `19.4k`, `258k`, `1.0M`.
///
/// The decimal drops once the mantissa needs three digits (`258k`, not
/// `258.4k`) so the panel's numeric column stays narrow.
String formatTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final k = n / 1000;
    return k < 100 ? '${k.toStringAsFixed(1)}k' : '${k.round()}k';
  }
  final m = n / 1000000;
  return m < 100 ? '${m.toStringAsFixed(1)}M' : '${m.round()}M';
}

const Map<String, String> _currencySymbols = {
  'USD': r'$',
  'EUR': '€',
  'GBP': '£',
  'JPY': '¥',
};

/// Cumulative session cost, e.g. `$0.42` or `SEK 1.50`. Always two decimals: a
/// measured `0.00` on a free/local model is a reading, not an absence.
String formatCost(UsageCost cost) {
  final amount = cost.amount.toStringAsFixed(2);
  final symbol = _currencySymbols[cost.currency.toUpperCase()];
  return symbol == null ? '${cost.currency} $amount' : '$symbol$amount';
}

/// `8%`, or null when the agent reported no window — a percentage without a
/// denominator would be invented.
String? percentLabel(SessionUsage usage) {
  final f = usage.fraction;
  return f == null ? null : '${(f * 100).round()}%';
}

/// How much context is left, e.g. `239k before compaction`. Null unless both
/// halves were measured; clamped at zero, because providers sometimes report a
/// context slightly past the advertised window.
String? headroomLabel(SessionUsage usage) {
  final used = usage.contextTokens;
  final window = usage.contextWindow;
  if (used == null || window == null) return null;
  return '${formatTokens(math.max(0, window - used))} before compaction';
}

/// Share of cumulative input tokens served from the provider's prompt cache, or
/// null when input is unknown or zero (no denominator).
double? cacheShare(SessionUsageTotals totals) {
  final input = totals.input;
  final cached = totals.cachedInput;
  if (input == null || input <= 0 || cached == null) return null;
  return (cached / input).clamp(0.0, 1.0);
}

// ─── the ring ────────────────────────────────────────────────────────────────

/// Circular context gauge: a track with an arc sweeping clockwise from twelve
/// o'clock for [fraction] of the context window.
///
/// There is no "unmeasured" rendering, by design — a ring means "this share of a
/// whole", so without a known window there is no whole and nothing to draw.
/// [ContextUsageButton] renders nothing at all in that case rather than showing an
/// ambiguous empty ring, which is why [fraction] is non-nullable here.
///
/// Colour escalates through the sanctioned status hues (DESIGN.md → Colors):
/// neutral ink while there is headroom, [kStatusWarning] as it tightens,
/// `colorScheme.error` when compaction is imminent.
class ContextUsageRing extends StatelessWidget {
  /// Creates the ring for [fraction] (0–1).
  const ContextUsageRing({super.key, required this.fraction, this.size = 18});

  /// Share of the context window in use.
  final double fraction;

  /// Outer diameter in logical pixels.
  final double size;

  /// The arc colour for [fraction] under [cs].
  static Color colorFor(double fraction, ColorScheme cs) => switch (fraction) {
    >= 0.9 => cs.error,
    >= 0.7 => kStatusWarning,
    _ => cs.onSurface,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          fraction: fraction,
          arc: colorFor(fraction, cs),
          track: cs.onSurface.withValues(alpha: 0.16),
          stroke: size > 30 ? 4.5 : 2.5,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.arc,
    required this.track,
    required this.stroke,
  });

  final double fraction;
  final Color arc;
  final Color track;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = (math.min(size.width, size.height) - stroke) / 2;
    final centre = rect.center;

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );

    if (fraction <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -math.pi / 2, // twelve o'clock
      2 * math.pi * fraction.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction ||
      old.arc != arc ||
      old.track != track ||
      old.stroke != stroke;
}

// ─── the button ──────────────────────────────────────────────────────────────

/// Width of the desktop details popover, when the window has room for it.
const double kUsagePanelWidth = 300;

/// Margin kept between the popover and the window edges, matching
/// `kBudgetPopoverMargin`'s role in the sidebar-footer popover.
const double _kUsagePanelMargin = 8;

/// Floor for the popover's height cap, so a very short window still shows a
/// usable (scrollable) panel rather than a sliver. Mirrors the budget popover's
/// `_kMinPopoverHeight`.
const double _kUsagePanelMinHeight = 140;

/// Tap-target size for the ring, matching the composer's send button (36px) so
/// the footer's two bare icon controls agree.
const double kUsageTargetSize = 36;

/// Composer-footer control for context usage (SPEC-context-usage): a [ContextUsageRing]
/// that opens [ContextUsageDetails] on tap.
///
/// A 32pt tap target with no label, because the footer row is tight — the model
/// and config pills already contend for it, and a full-detail label ellipsized
/// its own numbers. The ring answers "is my context filling up?" at a glance;
/// the panel answers "by how much?" on demand.
///
/// Renders nothing until something has actually been measured: no agent reports
/// usage before its first turn, pi reports none at all unless
/// the `makit-pi-usage` extension is installed, and pi's reading is null right after a
/// compaction.
///
/// [desktop] selects the presentation, mirroring `ComposerConfigOptions`: an
/// anchored [MenuAnchor] popover, or a modal bottom sheet on mobile.
class ContextUsageButton extends ConsumerWidget {
  /// Creates the control for [sessionId].
  const ContextUsageButton({
    super.key,
    required this.sessionId,
    this.desktop = false,
  });

  /// The session whose usage this reads.
  final String sessionId;

  /// Anchor a desktop popover (true) or open a mobile bottom sheet (false).
  final bool desktop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(sessionUsageProvider(sessionId));
    final fraction = usage?.fraction;
    if (usage == null || fraction == null) return const SizedBox.shrink();

    final ring = ContextUsageRing(fraction: fraction);
    final tip = _tooltip(usage);

    if (!desktop) {
      return _target(
        context,
        ring: ring,
        tooltip: tip,
        onTap: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          // Scrollable, because the sheet's height is capped by the window while
          // the panel's height depends on how much the agent reported AND on how
          // much the rows wrap: at 320pt with a long session (33.7M billed) the
          // content ran 57px past the sheet and threw. Clipping there would have
          // hidden the cost line, which is the row people open this for.
          builder: (_) => SafeArea(
            child: SingleChildScrollView(
              child: ContextUsageDetails(usage: usage, sessionId: sessionId),
            ),
          ),
        ),
      );
    }

    final cs = Theme.of(context).colorScheme;
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        backgroundColor: WidgetStatePropertyAll(cs.surface),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: cs.outlineVariant),
          ),
        ),
      ),
      menuChildren: [
        // Sized to the WINDOW, not to a constant: `MenuAnchor` clamps a menu's
        // position but never its size, so a fixed 300pt panel opened from a
        // control at the right edge of a 280pt pane hung 36px off-screen — and a
        // 360pt-tall window put 75px of it below the bottom. Both are reachable
        // in a narrow split pane, which is where this control lives.
        Builder(
          builder: (context) {
            final window = MediaQuery.sizeOf(context);
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.max(
                  _kUsagePanelMinHeight,
                  window.height - 2 * _kUsagePanelMargin,
                ),
              ),
              child: SizedBox(
                // Floored at zero: `window.width - 2 * margin` goes negative below
                // 16pt, and a negative SizedBox width is a non-normalized
                // constraint — the layout asserts instead of rendering a cramped
                // panel. Reachable for a frame when the window shrinks under an
                // open popover. The height axis above was already safe, floored by
                // `_kUsagePanelMinHeight`; this axis had no floor.
                // (Found via SPEC-session-identity's identity panel, which copied this sizing.)
                width: math.max(
                  0,
                  math.min(
                    kUsagePanelWidth,
                    window.width - 2 * _kUsagePanelMargin,
                  ),
                ),
                // Scrolls inside the height cap rather than clipping the cost
                // line off the bottom. `primary: false` because `MenuAnchor`
                // already wraps its children in a scrollable that claims the
                // PrimaryScrollController; two claims on it is an error.
                child: SingleChildScrollView(
                  primary: false,
                  child: ContextUsageDetails(
                    usage: usage,
                    sessionId: sessionId,
                  ),
                ),
              ),
            );
          },
        ),
      ],
      builder: (context, controller, _) => _target(
        context,
        ring: ring,
        tooltip: tip,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  /// The tap target shared by both presentations — a bare icon control like the
  /// footer's `[+]` and send buttons, not a labelled pill.
  ///
  /// [kUsageTargetSize] rather than the 18px ring itself: an 18px hit area is not
  /// a thumb target. It matches the send button's deliberately compact footprint
  /// in this same row (see `Composer._buildSendSlot`), so the two bare controls
  /// are the same size. Note this row is NOT on the [kTouchRow] 44px scale — that
  /// is for list rows, and the composer explicitly tuned these controls smaller
  /// because the Material default "read oversized on phone".
  Widget _target(
    BuildContext context, {
    required Widget ring,
    required String tooltip,
    required VoidCallback onTap,
  }) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kUsageTargetSize / 2),
      child: SizedBox(
        width: kUsageTargetSize,
        height: kUsageTargetSize,
        child: Center(child: ring),
      ),
    ),
  );

  /// Hover summary — enough to avoid a click when the answer is "plenty left".
  String _tooltip(SessionUsage usage) {
    final pct = percentLabel(usage);
    final used = usage.contextTokens;
    final window = usage.contextWindow;
    if (pct != null && used != null && window != null) {
      return 'Context $pct — ${formatTokens(used)} of ${formatTokens(window)}';
    }
    if (used != null) return 'Context: ${formatTokens(used)} tokens';
    final cost = usage.cost;
    return cost == null ? 'Context usage' : 'Session cost ${formatCost(cost)}';
  }
}

// ─── the details panel ───────────────────────────────────────────────────────

/// Host-agnostic content of the context-usage panel (SPEC-context-usage): the context
/// reading up top, then the cumulative session totals, then cost.
///
/// The two token figures are deliberately kept in separate blocks with the
/// distinction spelled out, because they are easy to conflate and mean opposite
/// things: the context reading is what the model currently sees, while the
/// session total is everything billed across every turn (codex's total hit 39k
/// after two turns while the context held 19.5k).
class ContextUsageDetails extends ConsumerWidget {
  /// Creates the panel for [usage].
  ///
  /// [sessionId] is optional: without it the panel is exactly the SPEC-context-usage one.
  /// With it, the SPEC-session-timings D11 session-effort rollup is appended.
  const ContextUsageDetails({super.key, required this.usage, this.sessionId});

  /// The snapshot to describe.
  final SessionUsage usage;

  /// The session whose effort rollup to append, when there is one.
  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final totals = usage.totals;
    final cost = usage.cost;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kSpace12, kSpace12, kSpace12, 0),
          child: Text(
            'Context usage',
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
              letterSpacing: 0.8,
            ),
          ),
        ),
        _Hero(usage: usage),
        if (totals != null) _Totals(totals: totals),
        if (cost != null)
          _Section(
            children: [
              _Row(label: 'Cost', value: formatCost(cost), strong: true),
            ],
          ),
        if (sessionId case final id?)
          SessionEffortSection(
            rollup: ref.watch(sessionRollupProvider(id)),
            createdAt: ref.watch(
              sessionsProvider.select((s) => s.byId(id)?.createdAt),
            ),
            // Server time, never the device clock (D15).
            nowMs: ref.read(storeControllerProvider.notifier).serverNowMs(),
            historyLoaded: ref.watch(sessionHistoryLoadedProvider(id)),
          ),
        _Footnote(usage: usage),
      ],
    );
  }
}

/// Big ring + percentage + used-of-window + headroom.
class _Hero extends StatelessWidget {
  const _Hero({required this.usage});

  final SessionUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Non-null by construction: ContextUsageButton renders nothing unless
    // `fraction` is known, which requires both halves of the ratio.
    final fraction = usage.fraction!;
    final used = usage.contextTokens!;
    final window = usage.contextWindow!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kSpace12,
        kSpace10,
        kSpace12,
        kSpace12,
      ),
      child: Row(
        children: [
          ContextUsageRing(fraction: fraction, size: 52),
          const SizedBox(width: kSpace12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  percentLabel(usage)!,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: ContextUsageRing.colorFor(fraction, cs),
                  ),
                ),
                Text(
                  '${formatTokens(used)} of ${formatTokens(window)} tokens',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: kSpace2),
                  child: Text(
                    headroomLabel(usage)!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Cumulative billing rows, with the cache share as a small bar.
class _Totals extends StatelessWidget {
  const _Totals({required this.totals});

  final SessionUsageTotals totals;

  @override
  Widget build(BuildContext context) {
    final share = cacheShare(totals);
    final cached = totals.cachedInput;
    return _Section(
      children: [
        if (totals.total case final v?)
          _Row(label: 'Session total', value: formatTokens(v), strong: true),
        if (totals.input case final v?)
          _Row(label: 'Input', value: formatTokens(v)),
        if (share != null && cached != null) ...[
          _Row(
            label: '└ from cache',
            value: '${formatTokens(cached)} · ${(share * 100).round()}%',
          ),
          Padding(
            padding: const EdgeInsets.only(top: kSpace4, bottom: kSpace2),
            child: _MiniBar(fraction: share),
          ),
        ],
        if (totals.output case final v?)
          _Row(label: 'Output', value: formatTokens(v)),
        if (totals.reasoning case final v? when v > 0)
          _Row(label: 'Reasoning', value: formatTokens(v)),
      ],
    );
  }
}

/// The honest caveats, varying by what the agent actually reported.
class _Footnote extends StatelessWidget {
  const _Footnote({required this.usage});

  final SessionUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final totals = usage.totals;
    final total = totals?.total;
    final used = usage.contextTokens;

    final text = total != null && used != null
        // Both figures are on screen; say which is which or they get conflated.
        ? '${formatTokens(total)} has been billed across all turns; '
              '${formatTokens(used)} is what the model currently sees.'
        : totals == null && usage.cost != null
        ? 'This agent reports what is in context and the running cost, but no '
              'token breakdown.'
        : 'Token counts come from the provider, not an estimate.';

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(
        kSpace12,
        kSpace10,
        kSpace12,
        kSpace12,
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: cs.onSurfaceVariant,
          height: 1.35,
        ),
      ),
    );
  }
}

/// The session-effort rollup (SPEC-session-timings D11): how old this session is and how
/// much agent time is actually in it.
///
/// Lives in this panel because it is already the "facts about this session"
/// surface and these numbers are checked once an hour — they do not deserve
/// permanent chrome. Two time numbers rather than one because either alone
/// lies: a session opened three days ago holding four minutes of agent time is
/// described honestly only by both.
class SessionEffortSection extends StatelessWidget {
  /// Creates the rollup section.
  const SessionEffortSection({
    super.key,
    required this.rollup,
    required this.createdAt,
    required this.nowMs,
    required this.historyLoaded,
  });

  /// Totals derived from this session's completed turns.
  final TurnRollup rollup;

  /// Epoch ms the session was created, or null on a pre-SPEC-session-timings server (D12).
  final int? createdAt;

  /// Server-now, for the age (D15 — never the device clock).
  final int nowMs;

  /// Whether this client holds the whole event log (D16). False → render
  /// nothing: a tail-only session would report "3 turns" for a session of 40.
  final bool historyLoaded;

  @override
  Widget build(BuildContext context) {
    if (!historyLoaded) return const SizedBox.shrink();

    final age = createdAt == null ? null : formatElapsed(nowMs - createdAt!);
    final agent = formatElapsed(rollup.agentMs);
    final median = rollup.medianWallMs == null
        ? null
        : formatElapsed(rollup.medianWallMs!);

    return _Section(
      children: [
        if (age != null) _Row(label: 'Age', value: age),
        if (agent != null) _Row(label: 'Agent time', value: agent),
        _Row(
          // D20: hard-coded English with an explicit singular.
          label: rollup.turnCount == 1 ? 'Turn' : 'Turns',
          value: '${rollup.turnCount}',
        ),
        if (median != null) _Row(label: 'Median turn', value: median),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    padding: const EdgeInsets.symmetric(
      horizontal: kSpace12,
      vertical: kSpace10,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.strong = false});

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSpace2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 4px bar for the cache share — the brand green, since a cache hit is a win.
class _MiniBar extends StatelessWidget {
  const _MiniBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Stack(
          children: [
            ColoredBox(color: cs.onSurface.withValues(alpha: 0.16)),
            FractionallySizedBox(
              widthFactor: fraction,
              child: ColoredBox(color: cs.primary),
            ),
          ],
        ),
      ),
    );
  }
}
