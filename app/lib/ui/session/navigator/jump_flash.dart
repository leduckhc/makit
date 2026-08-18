/// The landing highlight: a brief outline on the row a jump just landed on
/// (SPEC-message-navigator).
///
/// Not decoration. It does two jobs no other feedback covers: it confirms the
/// jump *did* something when the target was already on screen (otherwise
/// indistinguishable from a dead click), and it gives the eye a target when the
/// render layer gave up slightly short of the row.
///
/// The row owns the animation rather than a timer clearing shared state — a
/// pending `Timer` trips `flutter_test`'s "a Timer is still pending" assert in
/// every test that jumps without waiting it out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import 'transcript_jumper.dart';

/// Outlines [child] when the last jump in [sessionId] landed on [position].
class JumpFlashHighlight extends ConsumerWidget {
  /// Wraps [child], the row at [position].
  const JumpFlashHighlight({
    super.key,
    required this.sessionId,
    required this.position,
    required this.child,
  });

  /// Session the row belongs to.
  final String sessionId;

  /// Item position of this row.
  final int position;

  /// The row itself.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flash = ref.watch(jumpFlashProvider(sessionId));
    if (flash == null || flash.position != position) return child;
    return TweenAnimationBuilder<double>(
      // Keyed by serial so jumping to the same row twice replays the animation
      // instead of sitting at its finished value.
      key: ValueKey(flash.serial),
      tween: Tween(begin: 1, end: 0),
      duration: kJumpFlashDuration,
      curve: Curves.easeOut,
      builder: (context, t, _) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kRadius12),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: t),
            width: 2,
          ),
        ),
        child: child,
      ),
    );
  }
}
