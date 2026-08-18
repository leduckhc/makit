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

/// Requests, and reports on, a jump to a particular row of the transcript.
///
/// This is the seam between the widget layer (which knows *which message* the
/// user asked for) and the render layer (which is the only thing that knows
/// where an un-built row actually is). SPEC-message-navigator.
///
/// A jump **must** be resolved by [SliverGeometry.scrollOffsetCorrection] during
/// layout, never from a post-frame callback: the latter paints the wrong frame
/// first — the blink [_RenderAnchoredSliverList] exists to prevent. Requesting a
/// jump here therefore triggers a re-layout, and the correction converges inside
/// the same frame.
class TranscriptJumpTarget extends ChangeNotifier {
  _RenderAnchoredSliverList? _render;
  int? _childIndex;

  /// The child index being sought, or null when no jump is outstanding.
  int? get childIndex => _childIndex;

  /// Asks the list to bring the child at [childIndex] on screen.
  void request(int childIndex) {
    _childIndex = childIndex;
    notifyListeners();
  }

  /// Child index of the row at the *top* of the viewport, or null when nothing
  /// is laid out. The rail uses this to light the tick you are reading.
  int? get topVisibleChild => _render?.topVisibleChildIndex;

  /// Clears the outstanding request from inside layout, where notifying
  /// listeners would be illegal.
  void _resolve() => _childIndex = null;

  void _attach(_RenderAnchoredSliverList render) => _render = render;

  void _detach(_RenderAnchoredSliverList render) {
    if (_render == render) _render = null;
  }
}

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
    this.jumpTarget,
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

  /// Optional handle used to jump to a row (SPEC-message-navigator). Null = no navigator.
  final TranscriptJumpTarget? jumpTarget;

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
            jumpTarget: jumpTarget,
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
    this.jumpTarget,
  });

  final ValueGetter<bool> shouldAnchor;
  final TranscriptJumpTarget? jumpTarget;

  @override
  RenderSliverList createRenderObject(BuildContext context) {
    final element = context as SliverMultiBoxAdaptorElement;
    return _RenderAnchoredSliverList(
      childManager: element,
      shouldAnchor: shouldAnchor,
      jumpTarget: jumpTarget,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAnchoredSliverList renderObject,
  ) {
    renderObject
      ..shouldAnchor = shouldAnchor
      ..jumpTarget = jumpTarget;
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
    TranscriptJumpTarget? jumpTarget,
  }) {
    this.jumpTarget = jumpTarget;
  }

  /// Whether the user is reading history (as opposed to following the tail).
  ValueGetter<bool> shouldAnchor;

  /// How many in-layout corrections one jump may spend before giving up.
  ///
  /// `RenderViewport` aborts after a small number of correction cycles per
  /// frame, so a runaway walk would trip a framework assert. Giving up leaves
  /// the viewport close to the target instead — which the caller's landing
  /// flash covers.
  static const int _maxJumpCorrections = 5;

  /// How many corrections the ANCHOR may spend in one frame.
  ///
  /// A correction is expected to settle on the next pass: the row's new offset
  /// becomes the baseline, the re-run measures zero delta, done. It does not
  /// always converge — the applied delta is clamped at the newest end, so a row
  /// that keeps moving by a different amount keeps producing a nonzero delta.
  /// Unbounded, that walks through `RenderViewport`'s whole cycle budget, and
  /// layout then ENDS on a correction: children stay unpositioned, and the next
  /// pointer packet throws a null check inside `childMainAxisPosition`. That
  /// crash was logged 49 times. Three attempts is more than convergence needs.
  static const int _maxAnchorCorrections = 3;

  TranscriptJumpTarget? _jumpTarget;
  int _jumpCorrections = 0;
  int _anchorCorrections = 0;

  /// The jump handle, if any. Setting it re-parents the render-object link so
  /// [TranscriptJumpTarget.offsetForChild] reads this list.
  set jumpTarget(TranscriptJumpTarget? value) {
    if (_jumpTarget == value) return;
    final previous = _jumpTarget;
    if (previous != null) {
      previous.removeListener(_onJumpRequested);
      previous._detach(this);
    }
    _jumpTarget = value;
    if (value != null) {
      value._attach(this);
      value.addListener(_onJumpRequested);
    }
  }

  void _onJumpRequested() {
    _jumpCorrections = 0;
    markNeedsLayout();
  }

  @override
  void detach() {
    _jumpTarget?._detach(this);
    super.detach();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _jumpTarget?._attach(this);
  }

  @override
  void dispose() {
    _jumpTarget?.removeListener(_onJumpRequested);
    _jumpTarget?._detach(this);
    super.dispose();
  }

  /// Scroll offset of the laid-out child at [childIndex]; null when un-built.
  double? offsetForChild(int childIndex) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (data.keptAlive || data.index != childIndex) continue;
      return data.layoutOffset;
    }
    return null;
  }

  /// Mean extent of the laid-out rows; null when nothing is built.
  double? get meanBuiltExtent {
    var total = 0.0;
    var n = 0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (data.keptAlive) continue;
      total += paintExtentOf(child);
      n++;
    }
    return n == 0 ? null : total / n;
  }

  /// The row being held. The [RenderBox] itself is the identity: thanks to
  /// `findChildIndexCallback` the sliver *moves* existing children to their new
  /// index rather than rebuilding them, so the same object survives inserts.
  RenderBox? _anchorChild;

  /// [_anchorChild]'s scroll offset within this sliver at the end of the last
  /// layout. A change means content newer than it was added or grew.
  double? _anchorOffset;

  /// Child index of the top-most visible row at the end of the last layout.
  int? _topVisibleIndex;

  @override
  void performLayout() {
    super.performLayout();
    // A correction is already in flight (the list ran out of rows in the
    // direction it was reaching): let it settle before measuring anything.
    if (geometry!.scrollOffsetCorrection != null) return;

    // An outstanding jump takes precedence over anchoring: the whole point is
    // to move the viewport, so holding a row still would fight it.
    if (_jumpTarget?.childIndex != null) {
      final correction = _jumpCorrectionFor(_jumpTarget!.childIndex!);
      if (correction != null &&
          correction.abs() > precisionErrorTolerance &&
          _jumpCorrections < _maxJumpCorrections) {
        _jumpCorrections++;
        geometry = SliverGeometry(scrollOffsetCorrection: correction);
        return;
      }
      // Resolved, or out of attempts: stop seeking and re-baseline the anchor
      // below so the next content change holds the row we just landed on.
      _jumpTarget!._resolve();
      _jumpCorrections = 0;
      _rebaselineAnchor();
      return;
    }

    final held = _anchorChild;
    if (shouldAnchor() &&
        held != null &&
        held.parent == this &&
        _anchorCorrections < _maxAnchorCorrections) {
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
            _anchorCorrections++;
            geometry = SliverGeometry(scrollOffsetCorrection: applied);
            return;
          }
        }
      }
    }
    _rebaselineAnchor();
  }

  /// Where a row sits in the main axis, with a row the last layout did not
  /// position treated as just past the visible window.
  ///
  /// The framework's version is `childScrollOffset(child)! - scrollOffset`, a
  /// null check that throws for a child with no `layoutOffset`. A lazy sliver
  /// leaves one unpositioned when its layout ended on a correction the viewport
  /// ran out of cycles to settle. Everything that reads a child's position then
  /// throws: the pointer packet (49 crashes in the field), the semantics pass,
  /// paint. The cap above is what stops that state arising; this makes reading it
  /// harmless.
  ///
  /// Off-window rather than 0: a row with no position has no place on screen, so
  /// it must not paint, must not take a tap, and must not claim a semantics rect
  /// belonging to a row the user can actually see. `childScrollOffset` itself
  /// keeps returning null, because layout depends on that meaning "not laid out".
  @override
  double childMainAxisPosition(RenderBox child) {
    final offset = childScrollOffset(child);
    if (offset == null) return constraints.remainingPaintExtent + 1.0;
    return offset - constraints.scrollOffset;
  }

  /// Records the row to hold, its offset, and its index, at the end of a layout
  /// that did not issue a correction.
  void _rebaselineAnchor() {
    // This layout is settling, so the next frame starts with a full budget.
    _anchorCorrections = 0;
    final child = _topVisibleChild();
    _anchorChild = child;
    _anchorOffset = child == null ? null : childScrollOffset(child);
    _topVisibleIndex = child == null
        ? null
        : (child.parentData! as SliverMultiBoxAdaptorParentData).index;
  }

  /// How far the viewport must move to bring child [childIndex] on screen, or
  /// null when the jump cannot make progress (already there, or pinned at an
  /// end).
  ///
  /// When the target is laid out this is **exact**: put its far edge at the
  /// window's far edge, i.e. the row lands at the top of the screen with its
  /// replies below it — the useful framing when you jump back to a prompt.
  /// When it is not laid out we cannot know where it is, so we walk a screenful
  /// toward it and let the next layout pass look again; the lazy list builds more
  /// rows on the way. Every pass happens inside the same frame, so nothing
  /// intermediate is ever painted.
  double? _jumpCorrectionFor(int childIndex) {
    // A row that cannot exist is not worth walking towards: bail before moving
    // the viewport at all, so a bad index is a no-op rather than a scroll to the
    // end of history.
    final total = childManager.childCount;
    if (childIndex < 0 || childIndex >= total) return null;
    final window = constraints.remainingPaintExtent;
    final offset = offsetForChild(childIndex);
    if (offset != null) {
      final child = _childAt(childIndex)!;
      final want = offset + paintExtentOf(child) - window;
      return math.max(
        want - constraints.scrollOffset,
        -constraints.scrollOffset,
      );
    }
    // Not built: estimate how far away it is from the nearest row we *have*
    // measured. A one-screenful walk would need more passes than
    // `_maxJumpCorrections` allows on a long transcript; scaling by the mean row
    // height gets within a screen or two in a single pass, and the exact branch
    // above finishes the job on the next one.
    final (first, last) = _builtIndexRange();
    if (first == null || last == null) return null;
    final mean = meanBuiltExtent ?? window;
    if (childIndex > last) {
      final estimate = mean * (childIndex - last);
      return math.max(estimate, window * 0.5);
    }
    if (childIndex < first) {
      final estimate = mean * (childIndex - first);
      return math.max(estimate, -constraints.scrollOffset);
    }
    return null; // inside the built range but not found: nothing sensible to do
  }

  RenderBox? _childAt(int childIndex) {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (data.keptAlive || data.index != childIndex) continue;
      return child;
    }
    return null;
  }

  (int?, int?) _builtIndexRange() {
    int? first;
    int? last;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final data = child.parentData! as SliverMultiBoxAdaptorParentData;
      if (data.keptAlive) continue;
      final index = data.index;
      if (index == null) continue;
      first = first == null ? index : math.min(first, index);
      last = last == null ? index : math.max(last, index);
    }
    return (first, last);
  }

  /// Child index of the top-most visible row as of the last layout.
  ///
  /// Cached rather than computed on demand: callers are widgets rebuilding
  /// during *build*, where a render object's `constraints` are not yet valid.
  int? get topVisibleChildIndex => _topVisibleIndex;

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
