/// Turns "bring my Nth message on screen" into a landed scroll position
/// (SPEC-message-navigator).
///
/// Three index spaces are in play and conflating them lands the user one message
/// away from where they asked:
///
/// | space | meaning |
/// |---|---|
/// | item position | index into the ascending transcript (`chatItemsProvider`) |
/// | child index | what the reversed lazy list uses — see [childIndexForPosition] |
/// | scroll offset | reversed: 0 is the newest message |
///
/// The jump itself is resolved by the render layer during layout (see
/// [TranscriptJumpTarget]); this class only translates, seeds the fast path, and
/// owns the landing flash.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../transcript_list.dart';

/// How long a jumped-to row stays highlighted. The *row* owns this animation —
/// see [JumpFlash] for why there is no timer here.
const Duration kJumpFlashDuration = Duration(milliseconds: 900);

/// The most recent jump, as rows see it.
///
/// [serial] exists so that jumping to the *same* message twice still re-arms the
/// highlight: the position alone would not change, so no row would rebuild.
///
/// Deliberately **not** cleared on a timer. A pending [Timer] would trip
/// `flutter_test`'s "a Timer is still pending" assert in every test that jumps
/// without pumping 900ms, which is a footgun for each navigator's own tests. The
/// row animates its outline out instead, and this value simply records the last
/// jump — which the rail also uses to mark where you are.
@immutable
class JumpFlash {
  /// Creates a flash record for [position].
  const JumpFlash(this.position, this.serial);

  /// Item position that was jumped to.
  final int position;

  /// Monotonic counter; a change re-arms the highlight.
  final int serial;

  @override
  bool operator ==(Object other) =>
      other is JumpFlash &&
      other.position == position &&
      other.serial == serial;

  @override
  int get hashCode => Object.hash(position, serial);
}

/// The reversed-list child index that renders the item at [position], or null
/// when [position] does not exist.
///
/// Mirrors `transcriptChildIndexFinder`: item `p` of `n` renders at
/// `n - 1 - p`, shifted by one when a trailing row occupies child 0 (the
/// "working…" indicator or the inline ask card).
int? childIndexForPosition(
  int position, {
  required int itemCount,
  required bool hasTrailer,
}) {
  if (position < 0 || position >= itemCount) return null;
  return itemCount - 1 - position + (hasTrailer ? 1 : 0);
}

/// Jumps the transcript to a given item position.
class TranscriptJumper {
  /// Creates a jumper over [controller], resolving jumps through [target].
  ///
  /// [itemCount] and [hasTrailer] are read at call time, not captured: the
  /// trailing row comes and goes while the agent works, and outline mode changes
  /// the row count underneath us.
  TranscriptJumper({
    required this.target,
    required this.itemCount,
    required this.hasTrailer,
    required this.onFlash,
  });

  /// The render-layer handle that performs the jump during layout.
  final TranscriptJumpTarget target;

  /// Current number of transcript items (excluding any trailing row).
  final int Function() itemCount;

  /// Whether a trailing row currently occupies child index 0.
  final bool Function() hasTrailer;

  /// Called with the landed item position so the row can highlight itself.
  ///
  /// Fires even when the target was already on screen — that is the case where a
  /// jump is otherwise indistinguishable from a no-op — and even when the render
  /// layer gave up short, so the user's eye still has somewhere to go.
  final void Function(int position) onFlash;

  /// Brings the item at [position] on screen.
  void jumpToItem(int position) {
    final child = childIndexForPosition(
      position,
      itemCount: itemCount(),
      hasTrailer: hasTrailer(),
    );
    if (child == null) return;

    // One path for built and un-built rows alike. There *was* a "fast path" here
    // that jumped straight to a built row's known offset — but `jumpTo(offset)`
    // puts the row at the viewport's *near* edge while the in-layout correction
    // puts it at the *top*, so the same click landed differently depending on
    // whether the row happened to be built yet. The render object resolves a
    // built row inside the very next layout anyway, so the optimisation bought
    // nothing but that inconsistency. `jumpTo`/`animateTo` are never used.
    target.request(child);
    onFlash(position);
  }
}

/// The most recent jump within a session, for rows to highlight themselves.
///
/// A provider rather than something hanging off [TranscriptJumper] because the
/// rows that must render the highlight are *siblings* of whatever owns the
/// jumper (the navigator overlay, or the session screen's action menu), never its
/// descendants.
final jumpFlashProvider = StateProvider.family<JumpFlash?, String>(
  (ref, _) => null,
);

/// Records a jump to [position] in [sessionId], re-arming any existing highlight.
void recordJumpFlash(WidgetRef ref, String sessionId, int position) {
  final notifier = ref.read(jumpFlashProvider(sessionId).notifier);
  notifier.state = JumpFlash(position, (notifier.state?.serial ?? 0) + 1);
}
