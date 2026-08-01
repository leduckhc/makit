/// The prompt scrubber: a narrow invisible strip down the transcript's trailing
/// edge, with one dot per message you sent (SPEC-34).
///
/// **Why dots by index, not by scroll offset.** Like the rail, dots are placed
/// proportionally down the strip by message *order* (`i / (N-1)`), never by
/// scroll position. The transcript is a reversed lazy list, so rows that have
/// not been laid out have no offset to be proportional to; forcing one would
/// mean measuring the whole history — the lurch SPEC-21 removed.
///
/// **Why a vertical-drag recognizer, not an opaque blocker.** The strip is only
/// 22pt wide and hit-tests translucently through a *vertical* drag recognizer,
/// so a horizontal swipe still reaches the iOS edge-swipe-back gesture beneath
/// it. The `liveScroll` option decides *when* the transcript moves: continuously
/// as the thumb travels, or once on release with a preview in the meantime.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import 'message_navigator_overlay.dart';
import 'navigator_style.dart';

/// Width of the invisible strip. Kept narrow so a horizontal edge-swipe passes
/// through to the platform back gesture rather than being swallowed.
const double kScrubberWidth = 22;

/// Vertical padding at each end of the strip, so the first and last dots are not
/// jammed against the viewport edges.
const double kScrubberInset = 12;

/// Resting and hot dot diameters. The hot dot (nearest the thumb) is larger and
/// painted in `primary`.
const double _kDotResting = 6;
const double _kDotHot = 12;

/// The scrubber.
class MessageScrubber extends ConsumerStatefulWidget {
  /// Creates the scrubber for [context].
  const MessageScrubber({super.key, required this.context});

  /// The transcript state to navigate.
  final MessageNavigatorContext context;

  @override
  ConsumerState<MessageScrubber> createState() => _MessageScrubberState();
}

class _MessageScrubberState extends ConsumerState<MessageScrubber> {
  /// Index into `positions` under the thumb while dragging, or null at rest.
  int? _hot;

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(scrubberOptionsProvider);
    final animate = !MediaQuery.disableAnimationsOf(context);
    final scheme = Theme.of(context).colorScheme;
    final positions = widget.context.positions;

    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: kScrubberWidth,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final usable = math.max(
            0.0,
            constraints.maxHeight - 2 * kScrubberInset,
          );
          return GestureDetector(
            // Translucent + vertical-only: a horizontal swipe still reaches the
            // edge-swipe-back gesture beneath the strip.
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (d) =>
                _onDrag(d.localPosition.dy, usable, options.liveScroll),
            onVerticalDragUpdate: (d) =>
                _onDrag(d.localPosition.dy, usable, options.liveScroll),
            onVerticalDragEnd: (_) => _onRelease(options.liveScroll),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < positions.length; i++)
                  _dot(
                    i: i,
                    usable: usable,
                    isHot: i == _hot,
                    animate: animate,
                    scheme: scheme,
                  ),
                if (_hot != null)
                  _preview(_hot!, usable, options.timestamps, scheme),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Maps a thumb position to the nearest dot and, under [liveScroll], jumps
  /// there as the hot dot changes.
  void _onDrag(double dy, double usable, bool liveScroll) {
    final total = widget.context.positions.length;
    final fraction = usable <= 0 ? 0.0 : (dy - kScrubberInset) / usable;
    final index = (fraction * (total - 1)).round().clamp(0, total - 1);
    if (index == _hot) return;
    setState(() => _hot = index);
    if (liveScroll) {
      widget.context.jumper.jumpToItem(widget.context.positions[index]);
    }
  }

  /// Commits on release. Under [liveScroll] the transcript already followed the
  /// thumb, so this only clears the preview; otherwise it jumps exactly once.
  void _onRelease(bool liveScroll) {
    final hot = _hot;
    if (!liveScroll && hot != null) {
      widget.context.jumper.jumpToItem(widget.context.positions[hot]);
    }
    setState(() => _hot = null);
  }

  /// Vertical centre of dot [i] within the strip.
  double _dotCentre(int i, double usable) {
    final total = widget.context.positions.length;
    final fraction = total <= 1 ? 0.0 : i / (total - 1);
    return kScrubberInset + fraction * usable;
  }

  Widget _dot({
    required int i,
    required double usable,
    required bool isHot,
    required bool animate,
    required ColorScheme scheme,
  }) {
    final size = isHot ? _kDotHot : _kDotResting;
    final color = isHot
        // The hot dot owes WCAG 1.4.11's 3:1 against the surface as the active
        // control; `primary` clears it and reads as "this is where you'll land".
        ? scheme.primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    return AnimatedPositioned(
      duration: animate ? const Duration(milliseconds: 160) : Duration.zero,
      curve: Curves.easeOutCubic,
      top: _dotCentre(i, usable) - size / 2,
      right: (kScrubberWidth - size) / 2,
      child: Semantics(
        container: true,
        label: 'your message ${i + 1} of ${widget.context.positions.length}',
        child: AnimatedContainer(
          duration: animate ? const Duration(milliseconds: 160) : Duration.zero,
          curve: Curves.easeOutCubic,
          width: size,
          height: size,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }

  /// The card revealing the hot message, pinned beside its dot.
  Widget _preview(int hot, double usable, bool timestamps, ColorScheme scheme) {
    final total = widget.context.positions.length;
    final time = timestamps
        ? _relativeTime(widget.context.items[widget.context.positions[hot]].ts)
        : null;
    return Positioned(
      top: math.max(0, _dotCentre(hot, usable) - 8),
      right: kScrubberWidth + kSpace8,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Material(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(kRadius12),
          elevation: 8,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: kSpace12,
              vertical: kSpace8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  time == null
                      ? 'you · ${hot + 1}/$total'
                      : 'you · ${hot + 1}/$total · $time',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  widget.context.textAt(hot),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact "3m ago" for an epoch-millisecond timestamp, or null when [ts] is
/// zero — fixtures and backfilled history carry no real time, and "56 years
/// ago" is worse than nothing. Kept private and dependency-free on purpose.
String? _relativeTime(int ts) {
  if (ts == 0) return null;
  final delta = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(ts),
  );
  final seconds = delta.inSeconds;
  if (seconds < 60) return '${math.max(0, seconds)}s ago';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}
