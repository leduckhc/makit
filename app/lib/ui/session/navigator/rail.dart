/// The ripple rail: a cosy cluster of ticks in the transcript's top-right
/// corner, one per message you sent (SPEC-message-navigator).
///
/// **Why a cluster and not a full-height gutter.** Ticks are placed at fixed
/// spacing by message *order*, not proportionally to scroll position. That is not
/// a style choice: the transcript is a reversed lazy list, so rows that have not
/// been laid out have no scroll offset to be proportional to, and forcing one
/// would mean measuring the whole history — the lurch SPEC-chat-scroll-anchoring removed. Packing
/// them tightly is also what makes the ripple legible: spread out, it is three
/// lines growing.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import 'message_navigator_overlay.dart';
import 'navigator_style.dart';

/// Width of the invisible strip that maps a pointer to a tick index.
///
/// Ticks are ~1.5pt tall and (by default) 6pt apart — far below the 44pt minimum
/// hit target — so individual ticks are never hit-tested. The pointer's vertical
/// position is mapped to the nearest *index* across this strip instead.
const double kRailHitWidth = 70;

/// Inset of the cluster from the transcript's trailing edge.
const double kRailInset = 10;

/// Distance from the top of the viewport to the first tick.
const double kRailTop = 12;

/// Resting tick lengths by message length, when length-encoding is on.
const double _kLongTick = 20;
const double _kMediumTick = 15;
const double _kShortTick = 11;
const double _kUniformTick = 14;

/// Ripple: extra length at the crest and over the three neighbours either side.
const List<double> _kRippleGrowth = [30, 21, 12, 5];

/// Ripple: how far neighbours are pushed away from the crest.
const List<double> _kRipplePush = [0, 3.5, 2, 0.8];

/// The rail.
class MessageRail extends ConsumerStatefulWidget {
  /// Creates the rail for [context].
  const MessageRail({super.key, required this.context});

  /// The transcript state to navigate.
  final MessageNavigatorContext context;

  @override
  ConsumerState<MessageRail> createState() => _MessageRailState();
}

class _MessageRailState extends ConsumerState<MessageRail> {
  /// Index into `positions` under the pointer, or null when not hovering.
  int? _focus;

  @override
  Widget build(BuildContext context) {
    final options = ref.watch(railOptionsProvider);
    final spacing = options.spacing.toDouble();
    final ripple = options.ripple;
    final encodeLength = options.encodeLength;
    // Reduce motion: no growth animation, and no push either — the crest still
    // marks the hovered tick, it just does not move its neighbours.
    final animate = !MediaQuery.disableAnimationsOf(context);
    final positions = widget.context.positions;
    final scheme = Theme.of(context).colorScheme;

    final clusterHeight = (positions.length - 1) * spacing + 2;

    return Positioned(
      top: kRailTop,
      right: 0,
      width: kRailHitWidth,
      height: clusterHeight + kRailHitWidth, // generous vertical slack
      child: MouseRegion(
        opaque: false,
        onHover: (event) => _onHover(event.localPosition.dy, spacing),
        onExit: (_) => setState(() => _focus = null),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (details) => _onHover(details.localPosition.dy, spacing),
          onTap: _jumpToFocus,
          child: AnimatedBuilder(
            // Rebuild as the transcript scrolls so the "you are here" tick keeps
            // up. Cheap: the cluster is a handful of coloured boxes.
            animation: widget.context.controller,
            builder: (context, _) {
              final current = _currentIndex();
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var i = 0; i < positions.length; i++)
                    _tick(
                      i: i,
                      spacing: spacing,
                      ripple: ripple && animate,
                      encodeLength: encodeLength,
                      isCurrent: i == current,
                      animate: animate,
                      scheme: scheme,
                    ),
                  if (_focus != null) _peek(spacing, scheme),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _onHover(double dy, double spacing) {
    final positions = widget.context.positions;
    final index = ((dy - 1) / spacing).round().clamp(0, positions.length - 1);
    if (index != _focus) setState(() => _focus = index);
  }

  void _jumpToFocus() {
    final focus = _focus;
    if (focus == null) return;
    widget.context.jumper.jumpToItem(widget.context.positions[focus]);
  }

  /// Which of the user's messages governs what is currently on screen: the last
  /// one at or above the top of the viewport.
  int? _currentIndex() {
    final topChild = widget.context.target.topVisibleChild;
    if (topChild == null) return null;
    // Invert the child-index transform to get back to an item position.
    final items = widget.context.items.length;
    final trailer = widget.context.hasTrailer ? 1 : 0;
    final position = items - 1 - (topChild - trailer);
    final positions = widget.context.positions;
    int? found;
    for (var i = 0; i < positions.length; i++) {
      if (positions[i] <= position) found = i;
    }
    return found;
  }

  Widget _tick({
    required int i,
    required double spacing,
    required bool ripple,
    required bool encodeLength,
    required bool isCurrent,
    required bool animate,
    required ColorScheme scheme,
  }) {
    final distance = _focus == null ? 99 : (i - _focus!).abs();
    final isCrest = distance == 0;
    final grow = ripple && distance < _kRippleGrowth.length
        ? _kRippleGrowth[distance]
        : (isCrest ? _kRippleGrowth.first : 0.0);
    final push = ripple && distance > 0 && distance < _kRipplePush.length
        ? (i - _focus!).sign * _kRipplePush[distance]
        : 0.0;

    final width = _restingLength(i, encodeLength) + grow;
    final color = isCrest
        ? scheme.primary
        : isCurrent
        ? scheme.primary.withValues(alpha: 0.9)
        // 60%, not lower: a tick is a UI component and owes WCAG 1.4.11's 3:1
        // against the transcript surface. A 38% hairline does not reach it.
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);

    return AnimatedPositioned(
      duration: animate ? const Duration(milliseconds: 260) : Duration.zero,
      curve: Curves.easeOutCubic,
      top: i * spacing + push,
      right: kRailInset,
      child: Semantics(
        label: 'your message ${i + 1} of ${widget.context.positions.length}',
        button: true,
        child: AnimatedContainer(
          duration: animate ? const Duration(milliseconds: 260) : Duration.zero,
          curve: Curves.easeOutCubic,
          width: width,
          height: isCrest ? 2 : 1.5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ),
    );
  }

  double _restingLength(int i, bool encodeLength) {
    if (!encodeLength) return _kUniformTick;
    final length = widget.context.textAt(i).length;
    if (length > 60) return _kLongTick;
    if (length > 40) return _kMediumTick;
    return _kShortTick;
  }

  /// The card revealing the hovered message, pinned to the crest.
  Widget _peek(double spacing, ColorScheme scheme) {
    final focus = _focus!;
    final total = widget.context.positions.length;
    return Positioned(
      top: math.max(0, focus * spacing - 8),
      right: kRailInset + _kLongTick + _kRippleGrowth.first + 8,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Material(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(kRadius12),
          elevation: 8,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: kSpace12,
              vertical: 8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'you · ${focus + 1}/$total',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  widget.context.textAt(focus),
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
