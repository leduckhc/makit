/// The transcript's scrolling list.
///
/// Split out of `chat_transcript.dart` because it owns render-layer machinery:
/// the transcript is a reversed lazy list whose content changes constantly
/// underneath the user (streamed tokens, new items, a row being unfolded), and
/// keeping the rows the user is reading nailed to their screen position can only
/// be done *during layout* — see [_RenderAnchoredSliverList].
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'chat_transcript.dart' show kAnchorNearBottomPx;

/// A reversed (newest at offset 0) transcript list that holds the row the user
/// is reading in place when the transcript's content changes.
///
/// Shared by the mobile `SessionScreen` and the desktop `DesktopChatPane` so
/// both surfaces scroll identically by construction.
class TranscriptListView extends StatelessWidget {
  /// Creates the transcript list. [findChildIndexCallback] is required (not
  /// optional as on [ListView.builder]): without it the lazy list reconciles its
  /// built rows by *index*, so every new item shifts each row into a slot whose
  /// key no longer matches and the row — with its fold state, its keep-alive and
  /// its measured height — is thrown away and rebuilt.
  const TranscriptListView({
    super.key,
    required this.controller,
    required this.padding,
    required this.itemCount,
    required this.itemBuilder,
    required this.findChildIndexCallback,
  });

  /// The transcript's scroll controller (offset 0 == the newest message).
  final ScrollController controller;

  /// Insets around the list contents (room for the floating bars).
  final EdgeInsetsGeometry padding;

  /// Number of rows, trailing row included.
  final int itemCount;

  /// Builds the row at a reversed index (0 == visually bottom-most).
  final NullableIndexedWidgetBuilder itemBuilder;

  /// Maps a row key back to its current index. See the constructor.
  final int? Function(Key) findChildIndexCallback;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      controller: controller,
      // Reversed so the resting position (offset 0) is the newest message at the
      // bottom: the session opens pinned to the latest with no measuring pass,
      // and older rows build lazily only as the user scrolls up.
      reverse: true,
      slivers: [
        SliverPadding(
          padding: padding,
          sliver: _AnchoredSliverList(
            // Within the near-bottom band the transcript is following the tail,
            // where growing content *should* push older rows up and keep the
            // newest message at the bottom edge. Anchoring only kicks in once
            // the user has scrolled into history.
            shouldAnchor: () =>
                controller.hasClients &&
                controller.position.hasPixels &&
                controller.position.pixels > kAnchorNearBottomPx,
            delegate: SliverChildBuilderDelegate(
              itemBuilder,
              childCount: itemCount,
              findChildIndexCallback: findChildIndexCallback,
            ),
          ),
        ),
      ],
    );
  }
}

class _AnchoredSliverList extends SliverList {
  const _AnchoredSliverList({
    required super.delegate,
    required this.shouldAnchor,
  });

  final ValueGetter<bool> shouldAnchor;

  @override
  RenderSliverList createRenderObject(BuildContext context) {
    final element = context as SliverMultiBoxAdaptorElement;
    return _RenderAnchoredSliverList(
      childManager: element,
      shouldAnchor: shouldAnchor,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAnchoredSliverList renderObject,
  ) {
    renderObject.shouldAnchor = shouldAnchor;
  }
}

/// Keeps the top-most visible row pinned to its screen position while the
/// transcript changes underneath it.
///
/// The transcript is `reverse: true`, so scroll offsets are measured from the
/// newest message. That makes the newest end stable (good: the session opens
/// pinned to the latest) but every row *above* it shifts whenever content is
/// added or grows — which is constantly, in a live session: a new item is
/// inserted at the anchored end, streamed tokens extend the newest row, a tool
/// row unfolds. At a fixed pixel offset the user therefore sees the transcript
/// slide, and an unfolded row grows *upward*, shooting the header the user just
/// tapped off the top of the viewport.
///
/// The correction is computed from the anchor row's own layout offset, which is
/// exact, and returned as a [SliverGeometry.scrollOffsetCorrection], which
/// `RenderViewport` applies during layout (`offset.correctBy`) and re-runs the
/// layout — so no intermediate frame is ever painted. Correcting from a
/// post-frame callback instead paints the wrong frame first (a visible blink),
/// and correcting from the list's `maxScrollExtent` delta cannot work at all: for
/// a lazy list that number is an average-height *estimate* over the rows it has
/// not built, not a measure of what was added.
class _RenderAnchoredSliverList extends RenderSliverList {
  _RenderAnchoredSliverList({
    required super.childManager,
    required this.shouldAnchor,
  });

  /// Whether the user is reading history (as opposed to following the tail).
  ValueGetter<bool> shouldAnchor;

  /// The row being held. The [RenderBox] itself is the identity: thanks to
  /// `findChildIndexCallback` the sliver *moves* existing children to their new
  /// index rather than rebuilding them, so the same object survives inserts.
  RenderBox? _anchorChild;

  /// [_anchorChild]'s scroll offset within this sliver at the end of the last
  /// layout. A change means content newer than it was added or grew.
  double? _anchorOffset;

  @override
  void performLayout() {
    super.performLayout();
    // A correction is already in flight (the list ran out of rows in the
    // direction it was reaching): let it settle before measuring anything.
    if (geometry!.scrollOffsetCorrection != null) return;

    final held = _anchorChild;
    if (shouldAnchor() && held != null && held.parent == this) {
      final now = childScrollOffset(held);
      final before = _anchorOffset;
      if (now != null && before != null) {
        final delta = now - before;
        if (delta.abs() > precisionErrorTolerance) {
          // Never correct past the newest end: a row *shrinking* (a fold) close
          // to the bottom would otherwise push the viewport into overscroll.
          final applied = math.max(delta, -constraints.scrollOffset);
          // The row's new offset is the baseline for the re-run layout, which
          // then measures a zero delta and settles.
          _anchorOffset = before + applied;
          if (applied.abs() > precisionErrorTolerance) {
            geometry = SliverGeometry(scrollOffsetCorrection: applied);
            return;
          }
        }
      }
    }
    _anchorChild = _topVisibleChild();
    _anchorOffset = _anchorChild == null
        ? null
        : childScrollOffset(_anchorChild!);
  }

  /// The last row that starts inside the visible window — in a reversed
  /// viewport, the one at the *top* edge. Anchoring there is what makes an
  /// unfolding row grow downward from its header instead of upward off-screen.
  RenderBox? _topVisibleChild() {
    final windowEnd =
        constraints.scrollOffset + constraints.remainingPaintExtent;
    RenderBox? found;
    // Children are in index order, i.e. ascending scroll offset.
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (data.keptAlive) continue;
      final offset = data.layoutOffset;
      if (offset == null || offset >= windowEnd) continue;
      found = child;
    }
    return found;
  }
}
