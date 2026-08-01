/// Outline mode's affordance: a toggle that collapses the assistant away
/// (SPEC-34).
///
/// The *filtering* lives in `outline_mode.dart`, applied at the transcript's
/// source, so this widget is only the switch and the "you are in outline mode"
/// state. Clicking a prompt while outlined leaves the mode and lands on it,
/// which is the whole point: the outline is a way back into the conversation,
/// not a place to stay.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../store/chat_items.dart';
import '../../../store/store.dart';
import 'message_navigator_overlay.dart';
import 'navigator_style.dart';
import 'outline_mode.dart';

/// The outline toggle, pinned to the transcript's top-right corner.
class MessageOutline extends ConsumerWidget {
  /// Creates the toggle for [sessionId].
  const MessageOutline({
    super.key,
    required this.sessionId,
    required this.context,
  });

  /// Session being outlined.
  final String sessionId;

  /// The transcript state to navigate.
  final MessageNavigatorContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final on = ref.watch(outlineModeProvider(sessionId));
    // A prompt was tapped while outlined: the mode is already off, so the
    // transcript has re-expanded — land on the row the user picked. Post-frame
    // because the expanded list must exist before we can jump into it.
    ref.listen<int?>(outlineExitJumpProvider(sessionId), (_, position) {
      if (position == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        context.jumper.jumpToItem(position);
        ref.read(outlineExitJumpProvider(sessionId).notifier).state = null;
      });
    });
    final scheme = Theme.of(buildContext).colorScheme;
    final hidden = _hiddenTotal(ref);
    void toggle() =>
        ref.read(outlineModeProvider(sessionId).notifier).state = !on;
    return Positioned(
      top: kSpace8,
      right: kSpace12,
      child: Semantics(
        button: true,
        toggled: on,
        // Exclude the label of the Text inside, or it merges into this node and
        // the announced name becomes "outline · 8 hidden" instead of the intent.
        excludeSemantics: true,
        // …which also drops the InkWell's tap action, so re-declare it here or
        // the button announces but cannot be activated.
        onTap: toggle,
        label: on ? 'Leave outline mode' : 'Outline: show only your messages',
        child: Material(
          color: on ? scheme.primary : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(kRadius8),
          child: InkWell(
            borderRadius: BorderRadius.circular(kRadius8),
            onTap: toggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: kSpace8,
                vertical: kSpace4,
              ),
              child: Text(
                on ? 'outline · $hidden hidden' : 'outline',
                style: Theme.of(buildContext).textTheme.labelSmall?.copyWith(
                  color: on ? scheme.onPrimary : scheme.onSurfaceVariant,
                  fontWeight: on ? FontWeight.w600 : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// How many rows the outline is currently collapsing.
  ///
  /// Counted against the **unfiltered** transcript: `context.items` is already
  /// the outlined list while the mode is on, so measuring it against itself
  /// would always report zero.
  int _hiddenTotal(WidgetRef ref) {
    final options = ref.watch(outlineOptionsProvider);
    final all = ref.watch(chatItemsProvider(sessionId));
    final kept = outlineItems(all, hideTools: options.hideTools).length;
    return all.length - kept;
  }
}

/// Wraps a user message so that, **while outline mode is on**, tapping it leaves
/// the mode and lands on that prompt in the full transcript.
///
/// Applied by `chatItemWidget`, so both surfaces get it without either one
/// knowing about outline mode.
class OutlineJumpable extends ConsumerWidget {
  /// Wraps [child], the row rendering [item].
  const OutlineJumpable({
    super.key,
    required this.sessionId,
    required this.item,
    required this.child,
  });

  /// Session the row belongs to.
  final String sessionId;

  /// The user message this row renders.
  final UserMessageItem item;

  /// The row itself.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(outlineModeProvider(sessionId))) return child;
    return Semantics(
      button: true,
      label: 'Open this message in the full transcript',
      child: InkWell(
        onTap: () {
          // Identify the row by seq (unique per session) against the unfiltered
          // transcript: the outlined list's indices are not item positions.
          final all = ref.read(chatItemsProvider(sessionId));
          final position = all.indexWhere((i) => i.seq == item.seq);
          ref.read(outlineModeProvider(sessionId).notifier).state = false;
          if (position >= 0) {
            ref.read(outlineExitJumpProvider(sessionId).notifier).state =
                position;
          }
        },
        child: child,
      ),
    );
  }
}
