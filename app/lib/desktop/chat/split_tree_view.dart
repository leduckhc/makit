import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/theme.dart';

import 'groups/group.dart' show GroupKind;
import 'groups/group_bar.dart';
import 'groups/groups_controller.dart' show groupsControllerProvider;
import 'groups/membership_bar.dart';
import 'open_in_ide.dart';
import 'selected_session.dart' show selectedWorktreeProvider;
import 'sidebar_layout.dart' show sidebarCollapsedProvider, kTrafficLightInset;
import 'split_view.dart';
import 'title_bar_strip.dart' show SidebarToggleButton;
import 'panes/split_node.dart';
import 'panes/workspace_controller.dart';

/// Width/height of the draggable divider strip between two splitter children.
const double _kDividerExtent = 8;

/// Renders the desktop/iPad workspace: the recursive split/tab tree of the
/// [WorkspaceController]. A [Splitter] becomes a resizable two-child divider; a
/// [Split] becomes a tab strip over the active tab's chat (see [SplitView]).
class WorkspaceView extends ConsumerWidget {
  /// Creates the workspace view.
  const WorkspaceView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workspaceControllerProvider);
    final collapsed = ref.watch(sidebarCollapsedProvider);
    // Decision 11: the IDE launcher targets the **active pane's** worktree.
    // With no pane focused in a worktree group it falls back to that group's
    // own scope (a worktree group always owns a folder); a board with no pane
    // owns nothing, so the path is null and the launcher renders disabled.
    final worktree = ref.watch(selectedWorktreeProvider);
    // Narrow: `activeGroupProvider` yields the whole Group, whose `==` includes
    // its tree, so watching it here would rebuild the strip on every divider
    // drag. Only the scope (or its absence, on a board) is read.
    final activeScope = ref.watch(
      groupsControllerProvider.select<String?>(
        (s) =>
            s.active.kind == GroupKind.worktree ? s.active.worktreePath : null,
      ),
    );
    final launcherPath = worktree?.path ?? activeScope;
    return Column(
      children: [
        // The title strip: the OS titlebar is hidden, so this is the macOS
        // window-drag zone (a DragToMoveArea layer behind the controls). It
        // hosts the scrolling group rail on the left and the IDE launcher
        // pinned on the right (decisions 10 & 11); no branch label lives here.
        ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Stack(
            children: [
              const Positioned.fill(
                child: DragToMoveArea(child: SizedBox.expand()),
              ),
              Padding(
                // Inset past the traffic lights only when the strip overlaps
                // them (sidebar folded); otherwise a small gutter, since the
                // sidebar owns the window's left edge.
                padding: EdgeInsets.only(
                  left: collapsed ? kTrafficLightInset : kSpace10,
                  right: kSpace8,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (collapsed) ...[
                      const SidebarToggleButton(collapse: false),
                      const SizedBox(width: kSpace8),
                    ],
                    // Decision 12: the rail alone scrolls; it fills the width
                    // it is given and clips its overflow internally.
                    const Expanded(child: GroupBar()),
                    // Decision 11: pinned outside the rail so it never scrolls
                    // away when the rail overflows with many groups. Vertically
                    // centred in the titlebar-height strip (TitleBarStrip's
                    // pattern) so it never dictates the strip height.
                    OpenInIdeButton(path: launcherPath),
                  ],
                ),
              ),
            ],
          ),
        ),
        // The tab-bar divider the old tabs had, restored for the outer rail:
        // a hairline just below the group tabs, above the membership bar.
        const Divider(height: 1),
        const MembershipBar(),
        Expanded(
          child: _NodeView(
            node: state.root,
            activeSplitId: state.activeSplitId,
          ),
        ),
      ],
    );
  }
}

/// Dispatches to a [SplitterView] or a [SplitView] for [node].
class _NodeView extends StatelessWidget {
  const _NodeView({required this.node, required this.activeSplitId});

  final SplitNode node;
  final String activeSplitId;

  @override
  Widget build(BuildContext context) {
    return switch (node) {
      final Split split => SplitView(
        key: ValueKey(split.id),
        split: split,
        active: split.id == activeSplitId,
      ),
      final Splitter splitter => _SplitterView(
        key: ValueKey(splitter.id),
        splitter: splitter,
        activeSplitId: activeSplitId,
      ),
    };
  }
}

/// A [Splitter]: two children sized by [Splitter.ratio] with a draggable
/// divider between them.
class _SplitterView extends ConsumerWidget {
  const _SplitterView({
    super.key,
    required this.splitter,
    required this.activeSplitId,
  });

  final Splitter splitter;
  final String activeSplitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final horizontal = splitter.axis == Axis.horizontal;
    final firstFlex = (splitter.ratio * 1000).round();
    final secondFlex = 1000 - firstFlex;
    final first = Expanded(
      flex: firstFlex,
      child: _NodeView(node: splitter.first, activeSplitId: activeSplitId),
    );
    final second = Expanded(
      flex: secondFlex,
      child: _NodeView(node: splitter.second, activeSplitId: activeSplitId),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final children = [first, second];
        // The two children abut with no gap so a tab strip's edge touches the
        // seam; the draggable divider is overlaid on the seam (straddling both
        // panes) rather than occupying layout space, which would push the
        // panes apart and leave an empty strip beside the tabs.
        final content = horizontal
            ? Row(children: children)
            : Column(children: children);
        final boundary = splitter.ratio * extent;
        final divider = _SplitterDivider(
          axis: splitter.axis,
          onDrag: (delta) {
            if (extent <= 0) return;
            // Nudge against the controller's live ratio so multiple move events
            // within one frame accumulate instead of clobbering each other.
            ref
                .read(workspaceControllerProvider.notifier)
                .adjustRatio(splitter.id, delta / extent);
          },
        );
        return Stack(
          children: [
            content,
            Positioned(
              left: horizontal ? boundary - _kDividerExtent / 2 : 0,
              right: horizontal ? null : 0,
              top: horizontal ? 0 : boundary - _kDividerExtent / 2,
              bottom: horizontal ? 0 : null,
              width: horizontal ? _kDividerExtent : null,
              height: horizontal ? null : _kDividerExtent,
              child: divider,
            ),
          ],
        );
      },
    );
  }
}

/// The draggable strip between two splitter children.
class _SplitterDivider extends StatelessWidget {
  const _SplitterDivider({required this.axis, required this.onDrag});

  final Axis axis;
  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final horizontal = axis == Axis.horizontal;
    return Semantics(
      label: 'Resize split',
      container: true,
      child: MouseRegion(
        cursor: horizontal
            ? SystemMouseCursors.resizeColumn
            : SystemMouseCursors.resizeRow,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: horizontal
              ? (details) => onDrag(details.delta.dx)
              : null,
          onVerticalDragUpdate: horizontal
              ? null
              : (details) => onDrag(details.delta.dy),
          child: SizedBox(
            width: horizontal ? _kDividerExtent : double.infinity,
            height: horizontal ? double.infinity : _kDividerExtent,
            child: Center(
              child: horizontal
                  ? const VerticalDivider(width: 1)
                  : const Divider(height: 1),
            ),
          ),
        ),
      ),
    );
  }
}
