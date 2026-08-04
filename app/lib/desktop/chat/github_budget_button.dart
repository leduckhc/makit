/// SPEC-32 §7 — the desktop sidebar footer's GitHub API budget indicator.
///
/// A single [IconButton] (the GitHub mark, coloured by budget level) that opens
/// an anchored popover explaining where the hourly quota went — including the
/// spend by *other tools on the same `gh` token*, which is usually why the
/// limit is hit and is invisible today.
///
/// The headline is deliberately **time-to-empty** ("18 min left"), not
/// percentage remaining: minutes are actionable, a percentage is not. The
/// healthy icon is deliberately colourless (`colorScheme.outline`, identical to
/// its footer neighbours) so the footer gains no permanent coloured status
/// light competing with the connection chip — colour appears only when there is
/// something to say.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../store/prefs/preference_entries.dart';
import '../../store/prefs/preferences_providers.dart';

/// Test hooks: stable keys for the bars, search row, throttle badge, expander
/// pill, and expanded diagnostics so widget tests can assert their presence
/// without depending on copy.
const Key kBudgetBarCoreKey = ValueKey('budget-bar-core');
const Key kBudgetBarGraphqlKey = ValueKey('budget-bar-graphql');
const Key kBudgetSearchRowKey = ValueKey('budget-search-row');
const Key kBudgetTickedTrackKey = ValueKey('budget-ticked-track');
const Key kBudgetThrottleBadgeKey = ValueKey('budget-throttle-badge');
const Key kBudgetHistoryPillKey = ValueKey('budget-history-pill');
const Key kBudgetSparklineKey = ValueKey('budget-sparkline');
const Key kBudgetLadderKey = ValueKey('budget-ladder');
const Key kBudgetRefreshKey = ValueKey('budget-refresh');
const Key kBudgetPauseKey = ValueKey('budget-pause');
const Key kBudgetAuthHintKey = ValueKey('budget-auth-hint');
const Key kBudgetPopoverKey = ValueKey('budget-popover');

/// Fixed popover width. The overlay math needs it up front to keep the panel on
/// screen, so it is a constant rather than an intrinsic measurement.
const double kBudgetPopoverWidth = 300;

/// Minimum breathing room between the popover and the window edges.
const double kBudgetPopoverMargin = kSpace8;

/// The mark's tint for a given budget [level], from theme tokens only.
///
/// `healthy` is `colorScheme.outline` — identical to the sibling footer icons,
/// so a healthy budget disappears into the row. `unknown` is a dimmed outline
/// (no reading yet); `warm` warns; `critical`/`paused` use the error hue.
Color githubBudgetIconColor(BudgetLevel level, ColorScheme cs) =>
    switch (level) {
      BudgetLevel.healthy => cs.outline,
      BudgetLevel.warm => kStatusWarning,
      BudgetLevel.critical => kDiffDel,
      BudgetLevel.paused => kDiffDel,
      BudgetLevel.unknown => cs.outline.withValues(alpha: 0.4),
    };

/// The footer GitHub API budget button: the coloured mark plus its click-to-open
/// popover. Renders gracefully when the budget is null or `unknown` (the real
/// state on first connect, before the server's startup refresh lands).
class GithubBudgetButton extends ConsumerStatefulWidget {
  /// Creates the button.
  const GithubBudgetButton({super.key});

  @override
  ConsumerState<GithubBudgetButton> createState() => _GithubBudgetButtonState();
}

class _GithubBudgetButtonState extends ConsumerState<GithubBudgetButton> {
  final _anchorKey = GlobalKey();
  final _controller = OverlayPortalController();
  bool _open = false;

  /// Captured in [initState] because [dispose] must still be able to withdraw
  /// the watch, and `ref` is unsafe once the element is unmounted. The notifier
  /// is owned by the container, which outlives this widget.
  late final StoreController _store;

  @override
  void initState() {
    super.initState();
    _store = ref.read(storeControllerProvider.notifier);
  }

  void _toggle() {
    setState(() {
      if (_open) {
        _controller.hide();
      } else {
        _controller.show();
      }
      _open = !_open;
    });
    _setWatching(_open);
  }

  void _close() {
    if (!_open) return;
    setState(() {
      _controller.hide();
      _open = false;
    });
    _setWatching(false);
  }

  /// Subscribe/unsubscribe from the server's fast budget cadence. Only an open
  /// panel justifies it: the reads are quota-exempt but still cost a `gh`
  /// subprocess each, and a closed panel has nobody to show the movement to.
  void _setWatching(bool watching) {
    _store.watchGithubBudget(watching);
  }

  @override
  void dispose() {
    // Esc/outside-tap route through _close, but disposal (navigating away, a
    // sidebar rebuild) does not — a leaked watcher would keep the server's fast
    // loop running until the socket dropped.
    if (_open) _setWatching(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final budget = ref.watch(githubBudgetProvider);
    final cs = Theme.of(context).colorScheme;
    final level = budget?.level ?? BudgetLevel.unknown;
    final color = githubBudgetIconColor(level, cs);

    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (ctx) => _overlay(ctx, budget),
      child: KeyedSubtree(
        key: _anchorKey,
        child: IconButton(
          tooltip: _hoverTooltip(budget),
          onPressed: _toggle,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          // Pressed tint while the popover is open, matching the mockup.
          style: _open
              ? IconButton.styleFrom(
                  backgroundColor: cs.onSurface.withValues(alpha: 0.11),
                )
              : null,
          icon: _GithubMark(color: color, slashed: level == BudgetLevel.paused),
        ),
      ),
    );
  }

  /// Anchors the popover to the icon, right-aligned and opening **upward** (the
  /// footer is the last row), then **clamps it into the window on both axes**.
  ///
  /// Clamping is not defensive padding — it is load-bearing. The button lives in
  /// the sidebar footer, so its right edge sits only ~216px from the left of the
  /// window at the default 320px sidebar width; right-aligning a
  /// [kBudgetPopoverWidth]-wide panel to it would place its left edge off-screen
  /// at roughly -84px (worse at [kSidebarMinWidth]). Vertically, the expanded
  /// panel is taller than a short window, so the available height above the icon
  /// caps it and the content scrolls inside.
  ///
  /// A full-bleed gesture layer dismisses on an outside tap; `Esc` dismisses via
  /// [CallbackShortcuts].
  Widget _overlay(BuildContext context, GithubBudget? budget) {
    final anchor = _anchorKey.currentContext?.findRenderObject();
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (anchor is! RenderBox || overlayBox is! RenderBox || !anchor.hasSize) {
      return const SizedBox.shrink();
    }
    final overlaySize = overlayBox.size;
    final topLeft = anchor.localToGlobal(Offset.zero, ancestor: overlayBox);

    // Horizontal: prefer right-aligned to the icon, then clamp inside the window.
    // `clampDouble` needs lo <= hi, which fails if the window is narrower than
    // the popover — fall back to the left margin in that case.
    final preferredLeft = topLeft.dx + anchor.size.width - kBudgetPopoverWidth;
    final maxLeft =
        overlaySize.width - kBudgetPopoverWidth - kBudgetPopoverMargin;
    final left = maxLeft <= kBudgetPopoverMargin
        ? kBudgetPopoverMargin
        : preferredLeft.clamp(kBudgetPopoverMargin, maxLeft);

    // Vertical: sit just above the icon, and never exceed the room above it.
    final bottom = overlaySize.height - topLeft.dy + kSpace6;
    final maxHeight = math.max(
      _kMinPopoverHeight,
      topLeft.dy - kSpace6 - kBudgetPopoverMargin,
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
                child: _BudgetPopover(budget: budget),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Floor for the popover's height cap, so a very short window still shows a
/// usable (scrollable) panel rather than a sliver.
const double _kMinPopoverHeight = 140;

/// The 18px GitHub mark. When [slashed] (paused), a diagonal stroke crosses it.
class _GithubMark extends StatelessWidget {
  const _GithubMark({required this.color, required this.slashed});

  final Color color;
  final bool slashed;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(PhosphorIconsLight.githubLogo, size: 18, color: color);
    if (!slashed) return icon;
    return SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        children: [
          icon,
          Positioned.fill(child: CustomPaint(painter: _SlashPainter(color))),
        ],
      ),
    );
  }
}

class _SlashPainter extends CustomPainter {
  const _SlashPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.1, size.height * 0.9),
      Offset(size.width * 0.9, size.height * 0.1),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SlashPainter old) => old.color != color;
}

/// One-line hover tooltip, in the same register as the sibling footer buttons.
String _hoverTooltip(GithubBudget? b) {
  if (b == null || b.level == BudgetLevel.unknown) {
    return 'GitHub API budget — not measured yet';
  }
  final rest = b.core?.remaining;
  final restPart = rest != null ? '${_fmt(rest)} REST left' : null;
  if (b.level == BudgetLevel.healthy) {
    return ['GitHub API budget — healthy', ?restPart].join(' · ');
  }
  final ms = b.msUntilEmpty;
  final parts = <String>[
    if (ms != null)
      'quota runs out in ${(ms / 60000).round()} min'
    else
      'GitHub API budget — ${b.level.name}',
    ?restPart,
    'click for detail',
  ];
  return parts.join(' · ');
}

// ─────────────────────────────── popover ──────────────────────────────────

/// The anchored popover. Collapsed by default; the "Burn history" pill expands
/// the diagnostics in place, and that expanded flag persists across opens and
/// restarts via [budgetHistoryExpandedPreference].
class _BudgetPopover extends ConsumerWidget {
  const _BudgetPopover({required this.budget});

  final GithubBudget? budget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final b = budget;
    final unknown = b == null || b.level == BudgetLevel.unknown;
    return Material(
      key: kBudgetPopoverKey,
      color: cs.surfaceContainerLow,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(kRadius12),
      child: Container(
        width: kBudgetPopoverWidth,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius12),
          border: Border.all(color: cs.outlineVariant),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace12,
          vertical: kSpace12,
        ),
        child: SingleChildScrollView(
          // The expanded panel is ~540px; in a short window the overlay caps our
          // height (see `_overlay`) and the content scrolls inside it rather
          // than running off the top of the screen. Unconstrained, this sizes to
          // its content, so a tall window is unaffected.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(budget: b),
              const SizedBox(height: kSpace10),
              if (unknown)
                const _UnknownBody()
              else
                ..._measuredBody(context, ref, b),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _measuredBody(
    BuildContext context,
    WidgetRef ref,
    GithubBudget b,
  ) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final core = b.core;
    final graphql = b.graphql;
    final search = b.search;
    final headlineColor = switch (b.level) {
      BudgetLevel.warm => kStatusWarning,
      BudgetLevel.critical || BudgetLevel.paused => kDiffDel,
      _ => cs.onSurface,
    };
    final expanded = ref.preference(budgetHistoryExpandedPreference);

    final searchNonIdle = search != null && search.remaining < search.limit;

    return [
      _Headline(budget: b, color: headlineColor),
      const SizedBox(height: kSpace4),
      _Caption(budget: b),
      if (core != null)
        _BucketBar(
          key: kBudgetBarCoreKey,
          label: 'REST core',
          labelTip:
              'The main REST pool: 5,000 requests per hour per account. '
              'Spent by PR lookups and most gh commands.',
          bucket: core,
          level: b.level,
        ),
      if (graphql != null)
        _BucketBar(
          key: kBudgetBarGraphqlKey,
          label: 'GraphQL',
          labelTip:
              'A separate 5,000/hour pool. gh pr list and the '
              'unresolved-review-thread counts run on GraphQL, so this drains '
              'independently of REST — exhausting one does not touch the other.',
          bucket: graphql,
          level: b.level,
        ),
      if (searchNonIdle) _SearchRow(key: kBudgetSearchRowKey, bucket: search),
      if (core != null || graphql != null || search != null) _Legend(budget: b),
      if (b.throttles.isNotEmpty || b.retryAfterMs != null) _Banner(budget: b),
      const SizedBox(height: kSpace12),
      _PillRow(
        expanded: expanded,
        throttleCount: b.throttles.length,
        onToggle: () => ref
            .read(preferencesControllerProvider.notifier)
            .set(budgetHistoryExpandedPreference, !expanded),
        onRefresh: () =>
            ref.read(storeControllerProvider.notifier).refreshGithubBudget(),
      ),
      if (expanded)
        _Details(
          budget: b,
          onTogglePause: () => ref
              .read(storeControllerProvider.notifier)
              .setGithubPollingPaused(b.level != BudgetLevel.paused),
        ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.budget});

  final GithubBudget? budget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final resetAt = budget?.core?.resetAt ?? 0;
    return Row(
      children: [
        Icon(
          PhosphorIconsLight.githubLogo,
          size: 14,
          color: cs.onSurfaceVariant,
        ),
        const SizedBox(width: kSpace8),
        Expanded(
          child: _Explain(
            message:
                'Every GitHub read makit makes — PR identity, CI checks, '
                'review threads — spends from one hourly quota tied to your gh '
                'login. This panel is that quota.',
            child: Text(
              'GitHub API budget',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        if (resetAt > 0)
          _Explain(
            message:
                "GitHub's window is fixed, not rolling: the entire allowance "
                'returns at this instant, not gradually. Waiting it out is '
                'often faster than optimising.',
            child: Text(
              'resets ${_clock(resetAt)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// The `unknown`/no-auth body — headline `—` and a "not measured" caption. This
/// is the first-connect state; it must never throw or show a half-empty skeleton.
class _UnknownBody extends StatelessWidget {
  const _UnknownBody();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Explain(
          message:
              'No reading available — with no token there is no quota to '
              'report.',
          child: Text(
            '—',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: kSpace6),
        Text(
          'Not measured yet. gh is not authenticated on this machine, so PR '
          'status is unavailable.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: kSpace10),
        // The one actionable thing in this state. Shown as a copyable command
        // rather than a button: makit does not run auth flows on the user's
        // behalf, and a button that only printed instructions would be a tease.
        _Explain(
          message:
              'Run this in a terminal to authenticate the GitHub CLI. '
              'makit does not run auth flows on your behalf.',
          child: SelectableText(
            'gh auth login',
            key: kBudgetAuthHintKey,
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurface,
              fontFamily: kMonoFontFamily,
            ),
          ),
        ),
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.budget, required this.color});

  final GithubBudget budget;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (big, unit) = _headlineText(budget);
    return _Explain(
      message:
          'How long the remaining quota lasts at the current burn rate. '
          'The number to act on: it can read minutes even while the raw '
          'remaining count still looks comfortable.',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            big,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          ),
          if (unit != null) ...[
            const SizedBox(width: kSpace6),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                unit,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Headline number + unit. Secondary (burst) limits and exhaustion read as
/// "REST calls left"; a live drain reads as "min of quota left".
(String, String?) _headlineText(GithubBudget b) {
  final core = b.core;
  if (b.retryAfterMs != null) {
    return (core != null ? _fmt(core.remaining) : '—', 'REST calls left');
  }
  if (core != null && core.remaining == 0) {
    return ('0', 'REST calls left');
  }
  final ms = b.msUntilEmpty;
  if (ms != null) {
    return ('${(ms / 60000).round()}', 'min of quota left');
  }
  return (core != null ? _fmt(core.remaining) : '—', 'REST calls left');
}

class _Caption extends StatelessWidget {
  const _Caption({required this.budget});

  final GithubBudget budget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final b = budget;
    final resetInMin = _resetInMinutes(b.core?.resetAt ?? 0);
    final String text;
    final String tip;
    if (b.retryAfterMs != null) {
      text = 'quota is fine — GitHub applied a secondary (burst) limit';
      tip =
          'Secondary limits punish burstiness, not volume: too many '
          'concurrent or too-rapid calls. Plenty of quota can remain while you '
          'are blocked. The fix is fewer parallel calls, not waiting for the '
          'reset.';
    } else if (b.msUntilEmpty != null) {
      text =
          'at the current ${_fmt(b.burnPerHour)} req/h burn'
          '${resetInMin != null ? ' · quota resets in $resetInMin min' : ''}';
      tip =
          'Requests per hour, measured over the last 10 minutes and '
          'extrapolated. Compare against the 300/h you can sustain forever.';
    } else {
      text = resetInMin != null
          ? 'quota resets in $resetInMin min'
          : 'measured just now';
      tip = 'The full allowance returns at once when the window resets.';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace12),
      child: _Explain(
        message: tip,
        child: Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// One hourly bucket: label + remaining/limit, over a stacked spend bar
/// (green = makit's spend, violet = other tools on the same token).
class _BucketBar extends StatelessWidget {
  const _BucketBar({
    super.key,
    required this.label,
    required this.labelTip,
    required this.bucket,
    required this.level,
  });

  final String label;
  final String labelTip;
  final BudgetBucket bucket;
  final BudgetLevel level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mineColor = switch (level) {
      BudgetLevel.warm => kStatusWarning,
      BudgetLevel.critical || BudgetLevel.paused => kDiffDel,
      _ => kMakitAccent,
    };
    final small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: kSpace8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: _Explain(
                  message: labelTip,
                  child: Text(
                    label,
                    style: small?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
              _Explain(
                message: 'Requests still available in this window.',
                child: Text(_fmt(bucket.remaining), style: small),
              ),
              const SizedBox(width: kSpace4),
              Text(
                '/ ${_fmt(bucket.limit)} left',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: kSpace4),
          _Explain(
            message:
                'Full width = the whole hourly allowance. The filled '
                'portion is what has already been spent, split by who spent it.',
            child: _SpendBar(
              mine: bucket.mine,
              others: bucket.others,
              limit: bucket.limit,
              mineColor: mineColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// A 4px stacked track: [mineColor] for makit's spend, violet for other tools,
/// the rest left as the empty track.
class _SpendBar extends StatelessWidget {
  const _SpendBar({
    required this.mine,
    required this.others,
    required this.limit,
    required this.mineColor,
    this.ticked = false,
  });

  final int mine;
  final int others;
  final int limit;
  final Color mineColor;
  final bool ticked;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final span = limit <= 0 ? 1 : limit;
    final mineFlex = ((mine / span) * 1000).round().clamp(0, 1000);
    final othersFlex = ((others / span) * 1000).round().clamp(
      0,
      1000 - mineFlex,
    );
    final restFlex = (1000 - mineFlex - othersFlex).clamp(0, 1000);
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        child: Row(
          // stretch, not the default centre: a childless [ColoredBox] under a
          // loose vertical constraint sizes to zero and paints nothing, so the
          // bar laid out at full width and 4px tall while staying invisible.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (mineFlex > 0)
              Expanded(
                flex: mineFlex,
                child: ColoredBox(color: mineColor),
              ),
            if (othersFlex > 0)
              Expanded(
                flex: othersFlex,
                child: ColoredBox(color: kBoardSwatch.withValues(alpha: 0.75)),
              ),
            if (restFlex > 0)
              Expanded(
                flex: restFlex,
                child: ticked
                    ? const _TickedTrack(key: kBudgetTickedTrackKey)
                    : ColoredBox(color: cs.surfaceContainerHighest),
              ),
          ],
        ),
      ),
    );
  }
}

/// The unspent part of a **per-minute** track: 4px ticks on a 6px pitch rather
/// than one continuous rail, so the search bucket reads at a glance as a bucket
/// that refills every minute and not as a slow hourly drain.
class _TickedTrack extends StatelessWidget {
  const _TickedTrack({super.key});

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _TickPainter(
      Theme.of(context).colorScheme.surfaceContainerHighest,
    ),
    size: Size.infinite,
  );
}

/// The tick geometry for a track of [size], shared by the painter and its tests
/// so there is no second implementation to drift from.
List<Rect> buildTickRects(Size size, {double pitch = 6, double tick = 4}) => [
  for (var x = 0.0; x < size.width; x += pitch)
    Rect.fromLTRB(x, 0, math.min(x + tick, size.width), size.height),
];

class _TickPainter extends CustomPainter {
  const _TickPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final tick in buildTickRects(size)) {
      canvas.drawRect(tick, paint);
    }
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.color != color;
}

/// The per-minute search row (30/minute). Rendered only when non-idle: a
/// seconds countdown and a spent fraction, never an hourly drain bar. makit
/// never searches, so a non-zero search bucket means something else is on the
/// token.
class _SearchRow extends StatelessWidget {
  const _SearchRow({super.key, required this.bucket});

  final BudgetBucket bucket;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final secs = _resetInSeconds(bucket.resetAt);
    final small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: kSpace8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: _Explain(
                  message:
                      'Search is capped per minute (30 authenticated), '
                      'not per hour — it throttles quickly and recovers '
                      'quickly. Shown only when something has used it recently; '
                      'makit itself does not search.',
                  child: Text(
                    'Search',
                    style: small?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
              Text(_fmt(bucket.remaining), style: small),
              const SizedBox(width: kSpace4),
              Text(
                '/ ${_fmt(bucket.limit)} this minute · ${secs}s',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: kSpace4),
          _Explain(
            message:
                'A per-minute bucket, not the hourly one — so this row '
                'reads in seconds.',
            child: _SpendBar(
              mine: 0,
              others: bucket.limit - bucket.remaining,
              limit: bucket.limit,
              mineColor: kMakitAccent,
              ticked: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.budget});

  final GithubBudget budget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Summed ACROSS buckets, so the totals can exceed any single bucket's limit
    // (5,000 + 5,000 + 30). Beside per-bucket bars a bare "5,001" reads as an
    // impossible number, hence the explicit "across all buckets" caption below.
    var mine = 0;
    var others = 0;
    for (final bucket in [budget.core, budget.graphql, budget.search]) {
      if (bucket == null) continue;
      mine += bucket.mine;
      others += bucket.others;
    }
    final base = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: kSpace10),
      child: Wrap(
        spacing: kSpace12,
        runSpacing: kSpace6,
        children: [
          _Explain(
            message:
                'Spent by this makit server: PR polling, repo snapshots, '
                'and PR actions you triggered.',
            child: _LegendItem(
              swatch: kMakitAccent,
              label: 'makit',
              value: mine,
              base: base,
            ),
          ),
          _Explain(
            message:
                'Spent by anything else on the same gh token — your '
                'terminal, Codex, other agents. makit cannot observe those '
                'calls; this is the gap between the quota GitHub reports and '
                "makit's own count. It is usually why the limit is hit.",
            child: _LegendItem(
              swatch: kBoardSwatch.withValues(alpha: 0.75),
              label: 'other tools',
              value: others,
              base: base,
            ),
          ),
          _Explain(
            message:
                'These two totals add up every bucket above, so they can '
                'exceed any single limit. makit\'s own share resets when the '
                'server restarts, since it can only count the calls it made '
                'itself.',
            child: Text(
              'across all buckets',
              style: base?.copyWith(color: cs.outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.swatch,
    required this.label,
    required this.value,
    required this.base,
  });

  final Color swatch;
  final String label;
  final int value;
  final TextStyle? base;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: swatch,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: kSpace6),
        Text('$label ', style: base),
        Text(_fmt(value), style: base?.copyWith(color: cs.onSurface)),
      ],
    );
  }
}

/// The throttle banner: what the gateway has already changed to protect quota.
class _Banner extends StatelessWidget {
  const _Banner({required this.budget});

  final GithubBudget budget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = budget;
    final hot =
        b.level == BudgetLevel.critical || b.level == BudgetLevel.paused;
    final tone = hot ? kDiffDel : kStatusWarning;
    final String text;
    final String tip;
    if (b.retryAfterMs != null) {
      text =
          'Backing off ${(b.retryAfterMs! / 1000).round()}s per Retry-After. '
          'Concurrency reduced to 2.';
      tip =
          'The correct response is fewer parallel calls, not waiting for the '
          'hourly reset — so the gateway lowers its concurrency cap instead of '
          'pausing.';
    } else if (b.level == BudgetLevel.paused) {
      text =
          'Polling paused. PR pills show the last known state, dimmed, '
          'until the quota resets.';
      tip =
          'A throttled lookup used to return "no PR", which the watcher '
          'broadcast as "the PR is gone" — so pills vanished. Now the last '
          'known state is kept and dimmed.';
    } else {
      text = 'Polling stretched; comment counts on demand.';
      tip =
          'What the gateway has already changed to protect the quota. '
          'Automatic — nothing for you to do.';
    }
    return Padding(
      padding: const EdgeInsets.only(top: kSpace12),
      child: _Explain(
        message: tip,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace10,
            vertical: kSpace8,
          ),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(kRadius8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(PhosphorIconsLight.warning, size: 14, color: tone),
              const SizedBox(width: kSpace8),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(color: tone),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Burn history" expander pill (with an active-throttle count badge) and
/// the display-only Refresh label.
class _PillRow extends StatelessWidget {
  const _PillRow({
    required this.expanded,
    required this.throttleCount,
    required this.onToggle,
    required this.onRefresh,
  });

  final bool expanded;
  final int throttleCount;
  final VoidCallback onToggle;

  /// Re-reads the quota via the exempt `/rate_limit` endpoint — free to press.
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        // NOT Flexible: `Spacer`/`Expanded` below already claims the slack, and a
        // Flexible here would split the free space with it 1:1 and squeeze this
        // pill until its label ellipsised ("Burn hi…"). The pill sizes to its
        // content; the row's spare width goes to the Refresh side, which is the
        // element that may safely shrink.
        _Explain(
          message:
              'Show the last hour of spend and the full throttling '
              'ladder.',
          child: InkWell(
            key: kBudgetHistoryPillKey,
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
                    'Burn history',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: expanded ? cs.onSurface : cs.onSurfaceVariant,
                    ),
                  ),
                  if (throttleCount > 0) ...[
                    const SizedBox(width: kSpace6),
                    _Explain(
                      message:
                          'Number of throttles currently in force. Hidden '
                          'when nothing has been shed, so the pill only draws '
                          'your eye when it has news.',
                      child: Container(
                        key: kBudgetThrottleBadgeKey,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          color: kStatusWarning.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '$throttleCount',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: kStatusWarning,
                          ),
                        ),
                      ),
                    ),
                  ],
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
        // Expanded (not Spacer + Flexible) so the slack is claimed exactly once:
        // it right-aligns Refresh and, under a large text scale, lets Refresh be
        // the thing that shrinks rather than overflowing the row.
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _Explain(
              message:
                  'Re-read the quota from GitHub. Uses the /rate_limit '
                  'endpoint, which GitHub exempts — so checking your budget '
                  'never spends it.',
              child: InkWell(
                key: kBudgetRefreshKey,
                borderRadius: BorderRadius.circular(kSpace6),
                onTap: onRefresh,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: kSpace6,
                    vertical: kSpace2,
                  ),
                  child: Text(
                    'Refresh',
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

/// The expanded diagnostics: the 60-slot sparkline and the degradation ladder.
class _Details extends StatelessWidget {
  const _Details({required this.budget, required this.onTogglePause});

  final GithubBudget budget;

  /// Pauses/resumes *background* polling only — user actions still draw on the
  /// reserve, and PR pills keep their last-known state rather than vanishing.
  final VoidCallback onTogglePause;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dlbl = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurfaceVariant,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.9,
    );
    // All-zero slots paint as a flat line on the floor, indistinguishable from a
    // broken chart, so treat "no data" as its own state.
    final hasBurnHistory = budget.history.any(
      (s) => s.mine > 0 || s.others > 0,
    );
    return Container(
      margin: const EdgeInsets.only(top: kSpace12),
      padding: const EdgeInsets.only(top: kSpace12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Explain(
            message:
                'Requests per hour, sampled each minute for the last '
                'hour. Reveals whether you are in a spike or a steady '
                'overspend — the fixes differ.',
            child: Text('LAST 60 MINUTES', style: dlbl),
          ),
          const SizedBox(height: kSpace8),
          _Explain(
            message:
                "Amber = makit's own calls. Violet = other tools on the "
                'same token. Dashed = 300/h, the rate you can sustain '
                'indefinitely. Above the dashes, you are borrowing from the '
                'next hour.',
            child: SizedBox(
              key: kBudgetSparklineKey,
              height: 40,
              child: hasBurnHistory
                  ? CustomPaint(
                      painter: _SparklinePainter(
                        history: budget.history,
                        makit: kStatusWarning,
                        others: kBoardSwatch,
                        sustainable: cs.outlineVariant,
                      ),
                      size: Size.infinite,
                    )
                  // An empty chart frame reads as a rendering failure. Say why it
                  // is empty instead: a fresh server has no minutes recorded yet.
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'No activity recorded yet.',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.outline,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: kSpace8),
          _Explain(
            message:
                'The fixed sequence of savings the gateway applies as '
                'quota drains, cheapest information sacrificed first.',
            child: Text('DEGRADATION LADDER', style: dlbl),
          ),
          const SizedBox(height: kSpace6),
          _Ladder(key: kBudgetLadderKey, applied: budget.throttles.length),
          const SizedBox(height: kSpace12),
          _Explain(
            message: budget.level == BudgetLevel.paused
                ? 'Resume background PR polling.'
                : 'Stop background PR polling until you turn it back on. PR '
                      'pills keep their last known state, dimmed.',
            child: OutlinedButton(
              key: kBudgetPauseKey,
              onPressed: onTogglePause,
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: cs.outlineVariant),
                foregroundColor: cs.onSurfaceVariant,
              ),
              child: Text(
                budget.level == BudgetLevel.paused
                    ? 'Resume polling'
                    : 'Pause polling now',
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The two sparkline series, built exactly as [_SparklinePainter.paint] draws
/// them so a test can assert the real geometry rather than a parallel helper.
///
/// `others` must be other tools' spend **alone**: it is labelled that way in the
/// legend and tooltip, and it is the panel's central insight. Plotting
/// `mine + others` there would always sit above the makit line and attribute
/// total burn to somebody else.
class SparklinePaths {
  const SparklinePaths({required this.mine, required this.others});
  final Path mine;
  final Path others;
}

/// Build both series for [history] within [size]. Shared by the painter and its
/// tests — there is deliberately no second implementation to drift from.
SparklinePaths buildSparklinePaths(List<BudgetHistorySlot> history, Size size) {
  var peak = 1;
  for (final slot in history) {
    final total = slot.mine + slot.others;
    if (total > peak) peak = total;
  }
  Path lineFor(int Function(BudgetHistorySlot) pick) {
    final path = Path();
    for (var i = 0; i < history.length; i++) {
      final x = history.length == 1
          ? 0.0
          : size.width * (i / (history.length - 1));
      final y = size.height - (pick(history[i]) / peak) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path;
  }

  return SparklinePaths(
    mine: lineFor((s) => s.mine),
    others: lineFor((s) => s.others),
  );
}

/// The 60-minute burn sparkline: amber (makit) over violet (other tools), with
/// a dashed sustainable-rate line. Pure paint, no dependency.
class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({
    required this.history,
    required this.makit,
    required this.others,
    required this.sustainable,
  });

  final List<BudgetHistorySlot> history;
  final Color makit;
  final Color others;
  final Color sustainable;

  @override
  void paint(Canvas canvas, Size size) {
    // Dashed sustainable-rate baseline at mid-height.
    final dash = Paint()
      ..color = sustainable
      ..strokeWidth = 1;
    const dashW = 3.0;
    for (var x = 0.0; x < size.width; x += dashW * 2) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(x + dashW, size.height / 2),
        dash,
      );
    }
    if (history.isEmpty) return;

    final paths = buildSparklinePaths(history, size);
    // Violet = other tools' spend alone, matching its tooltip and the legend.
    canvas.drawPath(
      paths.others,
      Paint()
        ..color = others.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      paths.mine,
      Paint()
        ..color = makit
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.history != history ||
      old.makit != makit ||
      old.others != others ||
      old.sustainable != sustainable;
}

/// The degradation ladder. The first [applied] rungs read as done/struck, the
/// next is highlighted, and the rest are pending.
///
/// The final rung is an **invariant**, not a step: "your own actions are never
/// blocked" is the promise the reserve exists to keep, so it is never struck
/// through however many throttles are active — striking it would state the
/// opposite of the guarantee.
class _Ladder extends StatelessWidget {
  const _Ladder({super.key, required this.applied});

  final int applied;

  /// Rungs that can actually be "applied" (the last entry in [_rungs] is the
  /// invariant, which cannot).
  static int get _shedRungs => _rungs.length - 1;

  static const _rungs = [
    'Comment counts → on demand',
    'Poll interval → 30s',
    'Next at <900 left: poll every 2 min',
    'At <300 left: pause polling, hold reserve',
    'Your own actions are never blocked',
  ];

  static const _tips = [
    'Unresolved-comment counts are the most expensive call we make — paged '
        'GraphQL, per PR, on every tick. They now load only when you look at '
        'that row.',
    'The fast poll is reserved for PRs with CI in flight; everything else has '
        'been stretched to 30s.',
    'Applies automatically when REST drops below 900 remaining.',
    'Background polling stops entirely and 300 requests are held back, so an '
        'action you take never fails for lack of quota.',
    'Throttling only ever slows the background poller. Your own actions always '
        'get budget from the reserve.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // Never let the count reach the invariant rung, however many throttles fire.
    final struck = applied.clamp(0, _shedRungs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _rungs.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: kSpace2),
            child: _Explain(
              message: _tips[i],
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i <= struck && i < _shedRungs
                          ? kStatusWarning
                          : cs.outlineVariant,
                    ),
                  ),
                  const SizedBox(width: kSpace8),
                  Expanded(
                    child: Text(
                      _rungs[i],
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: i == struck ? cs.onSurface : cs.onSurfaceVariant,
                        decoration: i < struck
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The shared explainer tooltip: a longer delay (~600ms) than a label tooltip,
/// wrapped, and it explains *why the thing matters* rather than restating it.
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

/// Thousands-separated integer, e.g. `1769` → `1,769`.
String _fmt(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Local wall-clock `HH:MM` for an epoch-ms reset instant.
String _clock(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${_two(dt.hour)}:${_two(dt.minute)}';
}

/// Whole minutes until [epochMs], or null when it is in the past/unknown.
int? _resetInMinutes(int epochMs) {
  if (epochMs <= 0) return null;
  final ms = epochMs - DateTime.now().millisecondsSinceEpoch;
  if (ms <= 0) return null;
  return (ms / 60000).round();
}

/// Whole seconds until [epochMs], clamped to a 0–60 minute-window display.
int _resetInSeconds(int epochMs) {
  if (epochMs <= 0) return 0;
  final ms = epochMs - DateTime.now().millisecondsSinceEpoch;
  return (ms / 1000).round().clamp(0, 60);
}
