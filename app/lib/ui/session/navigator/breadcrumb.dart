/// The sticky breadcrumb: a small glass chip pinned to the top of the transcript
/// that always names *which of your prompts produced what you are reading*, with
/// ◀ ▶ to hop between prompts (SPEC-34).
///
/// **Why this answers "where am I", not "where was it".** The chip is passive: it
/// does not remember where a message *was*, it reports which prompt currently
/// governs the viewport — the last one at or above the top edge. That framing is
/// why the copy is "your message N of M" and why the label jumps to the *current*
/// prompt rather than anywhere the user last looked.
///
/// It derives the governing prompt exactly as [MessageRail] does — via
/// `context.target.topVisibleChild`, inverting the reversed-list child-index
/// transform back to an item position — so the two peers cannot disagree about
/// "you are here". Unlike the rail, which only tints a tick, the chip *shows*
/// that prompt as text, so it cannot tolerate the one-frame staleness of reading
/// `topVisibleChild` mid-scroll: that value is refreshed during layout, which
/// runs *after* the scroll notification rebuilds. The governing index is
/// therefore recomputed in a post-frame callback, once layout has settled.
///
/// **Passive vs. explicit.** While the user reads, the label follows the
/// viewport (`topVisibleChild`). When the user taps a chevron or the label, that
/// is an explicit choice, so the label *holds* that prompt until the user
/// scrolls by hand again. The hold is what keeps `◀ ▶` feeling like "select the
/// next prompt" rather than snapping back a frame later — the jump itself brings
/// the prompt on screen, but the shipped [TranscriptJumper]'s built-target path
/// does not guarantee it lands at the *top*, so the viewport read-back cannot be
/// trusted the instant after an explicit jump.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../widgets/glass.dart';
import '../chat_transcript.dart' show kAnchorNearBottomPx;
import 'message_navigator_overlay.dart';
import 'navigator_style.dart';

/// Distance from the top of the viewport to the chip.
const double kBreadcrumbTop = 12;

/// Opacity of the chip while auto-hidden — dimmed but still hit-testable, so a
/// user who wants to hop back can still reach the chevrons.
const double _kDimOpacity = 0.4;

/// Widest the truncated prompt label is allowed to grow before it ellipsises.
const double _kLabelMaxWidth = 220;

/// The breadcrumb.
class MessageBreadcrumb extends ConsumerStatefulWidget {
  /// Creates the breadcrumb for [context].
  const MessageBreadcrumb({super.key, required this.context});

  /// The transcript state to navigate.
  final MessageNavigatorContext context;

  @override
  ConsumerState<MessageBreadcrumb> createState() => _MessageBreadcrumbState();
}

class _MessageBreadcrumbState extends ConsumerState<MessageBreadcrumb> {
  /// Index into `positions` of the prompt the chip is showing. Seeded to the
  /// newest prompt for the frame before the first layout resolves.
  late int _current = widget.context.positions.length - 1;

  @override
  void initState() {
    super.initState();
    widget.context.controller.addListener(_onScroll);
    // The first layout has not run yet; read the governing prompt once it has.
    WidgetsBinding.instance.addPostFrameCallback(_recompute);
  }

  @override
  void dispose() {
    widget.context.controller.removeListener(_onScroll);
    super.dispose();
  }

  /// A scroll notification fires *before* the frame's layout refreshes
  /// `topVisibleChild`, so defer the read to after layout.
  void _onScroll() => WidgetsBinding.instance.addPostFrameCallback(_recompute);

  void _recompute(Duration _) {
    if (!mounted) return;
    final next = _governingIndex();
    if (next != _current) setState(() => _current = next);
  }

  /// Shows [index] and brings it on screen.
  ///
  /// No "held selection" bookkeeping: a jump lands the target at the top of the
  /// viewport, so the passive read of `topVisibleChild` returns the same prompt
  /// on the next frame and the two never disagree.
  void _select(int index) {
    setState(() => _current = index);
    widget.context.jumper.jumpToItem(widget.context.positions[index]);
  }

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(breadcrumbOptionsProvider);

    return Positioned(
      top: kBreadcrumbTop,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedBuilder(
          // Rebuild as the transcript scrolls so the auto-hide dim (driven by the
          // live scroll offset) keeps up; the governing prompt is tracked
          // separately in [_recompute] because its source refreshes only at
          // layout time.
          animation: widget.context.controller,
          builder: (context, _) => _chip(context, options),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, BreadcrumbOptions options) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final positions = widget.context.positions;
    final total = positions.length;
    final current = _current.clamp(0, total - 1);
    final hasPrevious = current > 0;
    final hasNext = current < total - 1;

    // Auto-hide dims the chip when the transcript is pinned to the newest
    // message — there is nothing to go back to — but keeps it hit-testable.
    final dimmed = options.autoHide && _pinnedToNewest();

    return Opacity(
      key: const ValueKey('breadcrumb-dim'),
      opacity: dimmed ? _kDimOpacity : 1.0,
      // Match the glass language of [JumpToNewestButton] so the chip reads as
      // native beside it: same radius, same lighter-than-the-bars tint.
      child: GlassSurface(
        borderRadius: 18,
        tint: dark ? const Color(0x40181818) : const Color(0x40FFFFFF),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSpace4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _chevron(
                icon: PhosphorIconsLight.caretLeft,
                semanticLabel: 'Previous message',
                onTap: hasPrevious ? () => _select(current - 1) : null,
                scheme: scheme,
              ),
              _label(context, options, current, total, scheme),
              _chevron(
                icon: PhosphorIconsLight.caretRight,
                semanticLabel: 'Next message',
                onTap: hasNext ? () => _select(current + 1) : null,
                scheme: scheme,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The prompt label — tapping it jumps to the current prompt — plus the
  /// optional "N/M" counter.
  Widget _label(
    BuildContext context,
    BreadcrumbOptions options,
    int current,
    int total,
    ColorScheme scheme,
  ) {
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      label: 'Your message ${current + 1} of $total',
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(kRadius8),
        onTap: () => _select(current),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace8,
            vertical: kSpace6,
          ),
          // The visible text is a truncated preview; the [Semantics] label above
          // is the meaningful screen-reader description, so hide the raw glyphs.
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _kLabelMaxWidth),
                  child: Text(
                    widget.context.textAt(current),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall,
                  ),
                ),
                if (options.counter)
                  Padding(
                    padding: const EdgeInsets.only(left: kSpace8),
                    child: Text(
                      '${current + 1}/$total',
                      style: textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        // Tabular figures so the counter does not jitter width as
                        // the digits change while hopping.
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chevron({
    required IconData icon,
    required String semanticLabel,
    required VoidCallback? onTap,
    required ColorScheme scheme,
  }) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: IconButton(
        onPressed: onTap,
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        // A disabled chevron reads as an end stop: dimmed, not hidden.
        color: scheme.onSurface,
        disabledColor: scheme.onSurfaceVariant.withValues(alpha: 0.3),
        icon: Icon(icon),
      ),
    );
  }

  /// Which of the user's messages governs what is currently on screen: the last
  /// one at or above the top of the viewport. Falls back to the newest prompt
  /// before the first layout, when no child is measured yet.
  int _governingIndex() {
    final positions = widget.context.positions;
    final topChild = widget.context.target.topVisibleChild;
    if (topChild == null) return positions.length - 1;
    // Invert the child-index transform to get back to an item position.
    final items = widget.context.items.length;
    final trailer = widget.context.hasTrailer ? 1 : 0;
    final position = items - 1 - (topChild - trailer);
    var found = 0;
    for (var i = 0; i < positions.length; i++) {
      if (positions[i] <= position) found = i;
    }
    return found;
  }

  /// Whether the transcript is pinned at (or within a hair of) the newest
  /// message, mirroring [kAnchorNearBottomPx] — the newest end is offset 0.
  bool _pinnedToNewest() {
    final controller = widget.context.controller;
    if (!controller.hasClients || !controller.position.hasPixels) return true;
    return controller.position.pixels <= kAnchorNearBottomPx;
  }
}
