import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sidebar_layout.dart' show sidebarCollapsedProvider;
import 'split_view.dart';
import 'title_bar_strip.dart';
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
    return Column(
      children: [
        // The OS titlebar is hidden, so this strip is the macOS window-drag
        // zone; when the sidebar is folded it also owns the only "show sidebar"
        // affordance.
        ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: TitleBarStrip(
            leading: collapsed
                ? const SidebarToggleButton(collapse: false)
                : null,
          ),
        ),
        const Divider(height: 1),
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
    final first = Flexible(
      flex: firstFlex,
      child: _NodeView(node: splitter.first, activeSplitId: activeSplitId),
    );
    final second = Flexible(
      flex: secondFlex,
      child: _NodeView(node: splitter.second, activeSplitId: activeSplitId),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
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
        final children = [first, divider, second];
        return horizontal
            ? Row(children: children)
            : Column(children: children);
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
    return MouseRegion(
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
    );
  }
}
