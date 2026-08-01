/// Turns "bring my Nth message on screen" into a landed scroll position
/// (SPEC-34).
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
    required this.controller,
    required this.target,
    required this.itemCount,
    required this.hasTrailer,
  });

  /// The transcript's controller (offset 0 == newest).
  final ScrollController controller;

  /// The render-layer handle that performs the jump during layout.
  final TranscriptJumpTarget target;

  /// Current number of transcript items (excluding any trailing row).
  final int Function() itemCount;

  /// Whether a trailing row currently occupies child index 0.
  final bool Function() hasTrailer;

  /// The item position currently highlighted, or null.
  ///
  /// Rows watch this to draw the landing outline. It is set even when the target
  /// was already on screen — that is the case where a jump is otherwise
  /// indistinguishable from a no-op — and even when the render layer gave up
  /// short, so the user's eye still has somewhere to go.
  final ValueNotifier<JumpFlash?> flashed = ValueNotifier<JumpFlash?>(null);

  int _serial = 0;

  /// Brings the item at [position] on screen.
  void jumpToItem(int position) {
    final child = childIndexForPosition(
      position,
      itemCount: itemCount(),
      hasTrailer: hasTrailer(),
    );
    if (child == null) return;

    final known = target.offsetForChild(child);
    if (known != null && controller.hasClients) {
      // Fast path: the row is laid out, so its offset is exact. `jumpTo`, never
      // `animateTo` — stacked animations during a token stream (SPEC-21).
      // Cancel any request still outstanding from an earlier jump, or layout
      // would keep seeking *that* row and undo this one.
      target.cancel();
      controller.jumpTo(known.clamp(0.0, controller.position.maxScrollExtent));
    } else {
      // Un-built: the render object walks to it inside layout, so no
      // intermediate frame is painted.
      target.request(child);
    }
    _flash(position);
  }

  void _flash(int position) => flashed.value = JumpFlash(position, ++_serial);

  /// Releases the flash notifier.
  void dispose() => flashed.dispose();
}
