import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:window_manager/window_manager.dart';

import '../../../store/store.dart';
import '../desktop_chat_pane.dart';
import '../selected_session.dart';
import '../sidebar_layout.dart'
    show kTitleBarStripHeight, kTrafficLightInset, sidebarCollapsedProvider;
import 'pane_node.dart';
import 'pane_tree_controller.dart';

/// Width/height of the draggable divider strip between two split children.
const double _kDividerExtent = 8;

/// Height of a leaf pane's merged header (grip + session title + actions).
const double _kPaneHeaderHeight = 28;

/// Renders the desktop split-pane tree: a recursive layout of resizable
/// [PaneSplit]s whose leaves each host a [DesktopChatPane]. Replaces the single
/// pane in the chat shell.
class PaneTreeView extends ConsumerWidget {
  /// Creates the pane tree view.
  const PaneTreeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tree = ref.watch(paneTreeControllerProvider);
    // The OS titlebar is hidden (TitleBarStyle.hidden), so macOS keeps the top
    // strip as its native window-drag zone. Reserve it as an explicit
    // DragToMoveArea — matching the sidebar's `_Header` — so the top-most
    // pane's draggable header sits below it. Without this inset the native
    // titlebar swallows the drag and moves the whole window instead of the
    // pane.
    final collapsed = ref.watch(sidebarCollapsedProvider);
    return Column(
      children: [
        SizedBox(
          height: kTitleBarStripHeight,
          width: double.infinity,
          child: Stack(
            children: [
              const Positioned.fill(
                child: DragToMoveArea(child: SizedBox.expand()),
              ),
              // With the sidebar folded away the pane area owns the only
              // "show sidebar" affordance, cleared past the traffic lights.
              if (collapsed)
                Positioned(
                  left: kTrafficLightInset,
                  top: 3,
                  child: IconButton(
                    iconSize: 19,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    tooltip: 'Show sidebar',
                    icon: const Icon(Symbols.thumbnail_bar, weight: 300),
                    onPressed: () =>
                        ref.read(sidebarCollapsedProvider.notifier).state =
                            false,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _PaneNodeView(
            node: tree.root,
            activeLeafId: tree.activeLeafId,
          ),
        ),
      ],
    );
  }
}

/// Dispatches to a split or leaf view for [node].
class _PaneNodeView extends StatelessWidget {
  const _PaneNodeView({required this.node, required this.activeLeafId});

  final PaneNode node;
  final String activeLeafId;

  @override
  Widget build(BuildContext context) {
    return switch (node) {
      final PaneLeaf leaf => _PaneLeafView(
        leaf: leaf,
        active: leaf.id == activeLeafId,
      ),
      final PaneSplit split => _PaneSplitView(
        split: split,
        activeLeafId: activeLeafId,
      ),
    };
  }
}

/// A [PaneSplit]: two children sized by [PaneSplit.ratio] with a draggable
/// divider between them.
class _PaneSplitView extends ConsumerWidget {
  const _PaneSplitView({required this.split, required this.activeLeafId});

  final PaneSplit split;
  final String activeLeafId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final horizontal = split.axis == Axis.horizontal;
    final firstFlex = (split.ratio * 1000).round();
    final secondFlex = 1000 - firstFlex;
    final first = Flexible(
      flex: firstFlex,
      child: _PaneNodeView(node: split.first, activeLeafId: activeLeafId),
    );
    final second = Flexible(
      flex: secondFlex,
      child: _PaneNodeView(node: split.second, activeLeafId: activeLeafId),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final divider = _PaneDivider(
          axis: split.axis,
          onDrag: (delta) {
            if (extent <= 0) return;
            // Nudge against the controller's live ratio (not the snapshot
            // captured in this build) so multiple move events within one frame
            // accumulate instead of clobbering each other.
            ref
                .read(paneTreeControllerProvider.notifier)
                .adjustRatio(split.id, delta / extent);
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

/// The draggable strip between two split children.
class _PaneDivider extends StatelessWidget {
  const _PaneDivider({required this.axis, required this.onDrag});

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

/// A [PaneLeaf]: a draggable header strip over a [DesktopChatPane], wrapped as a
/// [DragTarget] that highlights the drop edge while a pane is dragged over it.
class _PaneLeafView extends ConsumerStatefulWidget {
  const _PaneLeafView({required this.leaf, required this.active});

  final PaneLeaf leaf;
  final bool active;

  @override
  ConsumerState<_PaneLeafView> createState() => _PaneLeafViewState();
}

class _PaneLeafViewState extends ConsumerState<_PaneLeafView> {
  final _key = GlobalKey();
  DropEdge? _hoverEdge;

  /// The drop edge nearest the drag position. [global] is the drag's
  /// [DragTargetDetails.offset] — the feedback widget's top-left, not the raw
  /// pointer. Since the same offset drives both the hover highlight and the
  /// accept, the highlight and the resulting dock are always consistent, so the
  /// small feedback-origin bias is intentional and harmless.
  DropEdge _edgeFor(Offset global) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return DropEdge.left;
    final local = box.globalToLocal(global);
    final size = box.size;
    final dx = (local.dx / size.width).clamp(0.0, 1.0);
    final dy = (local.dy / size.height).clamp(0.0, 1.0);
    final distances = <DropEdge, double>{
      DropEdge.left: dx,
      DropEdge.right: 1 - dx,
      DropEdge.top: dy,
      DropEdge.bottom: 1 - dy,
    };
    var nearest = DropEdge.left;
    var best = double.infinity;
    for (final entry in distances.entries) {
      if (entry.value < best) {
        best = entry.value;
        nearest = entry.key;
      }
    }
    return nearest;
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(paneTreeControllerProvider.notifier);
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) {
        if (details.data == widget.leaf.id) return false;
        setState(() => _hoverEdge = _edgeFor(details.offset));
        return true;
      },
      onMove: (details) {
        if (details.data == widget.leaf.id) return;
        final edge = _edgeFor(details.offset);
        if (edge != _hoverEdge) setState(() => _hoverEdge = edge);
      },
      onLeave: (_) => setState(() => _hoverEdge = null),
      onAcceptWithDetails: (details) {
        final edge = _edgeFor(details.offset);
        setState(() => _hoverEdge = null);
        controller.moveLeaf(details.data, widget.leaf.id, edge);
      },
      builder: (context, candidate, rejected) {
        return GestureDetector(
          onTap: () => controller.setActive(widget.leaf.id),
          child: Container(
            key: _key,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Column(
                    children: [
                      _PaneHeaderStrip(
                        leaf: widget.leaf,
                        active: widget.active,
                      ),
                      Expanded(
                        child: DesktopChatPane(
                          sessionId: widget.leaf.sessionId,
                          showHeader: false,
                          // Only the active pane tracks the global session /
                          // worktree selection; inactive panes stay empty.
                          trackGlobalSelection: widget.active,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_hoverEdge != null)
                  Positioned.fill(child: _DropHighlight(edge: _hoverEdge!)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The leaf's draggable tab: carries the leaf id and offers a close button.
class _PaneHeaderStrip extends ConsumerWidget {
  const _PaneHeaderStrip({required this.leaf, required this.active});

  final PaneLeaf leaf;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final controller = ref.read(paneTreeControllerProvider.notifier);
    // Only the active pane tracks the global selection; an inactive null pane
    // stays empty rather than mirroring whatever the sidebar last selected.
    final sessionId =
        leaf.sessionId ?? (active ? ref.watch(selectedSessionProvider) : null);
    final session = sessionId == null
        ? null
        : ref.watch(sessionsProvider).byId(sessionId);
    final title = sessionId == null
        ? 'Empty pane'
        : sessionPaneTitle(session, sessionId);
    final bar = SizedBox(
      height: _kPaneHeaderHeight,
      child: Row(
        children: [
          const SizedBox(width: 8),
          // A short grip pill is the drag affordance — softer than a row of
          // dots and reads as "grab to move" without a hard control.
          Container(
            width: 16,
            height: 4,
            decoration: BoxDecoration(
              color: active
                  ? cs.primary.withValues(alpha: 0.45)
                  : cs.onSurfaceVariant.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w400,
                color: active
                    ? cs.onSurface
                    : cs.onSurfaceVariant.withValues(alpha: 0.85),
              ),
            ),
          ),
          if (sessionId != null) SessionActionsMenu(sessionId: sessionId),
          IconButton(
            iconSize: 13,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            tooltip: 'Close pane',
            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
            icon: const Icon(Icons.close),
            onPressed: () {
              controller.setActive(leaf.id);
              controller.closeActive();
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
    return Draggable<String>(
      data: leaf.id,
      onDragStarted: () => controller.setActive(leaf.id),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: 160,
          height: _kPaneHeaderHeight,
          color: cs.primaryContainer,
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Semantics(
          label: 'Move pane',
          button: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => controller.setActive(leaf.id),
            child: ColoredBox(
              // Borderless tabs: transparent when idle, a faint accent wash on the
              // active pane's header so the focused pane reads softly rather than
              // with a hard outline.
              color: active
                  ? cs.primary.withValues(alpha: 0.06)
                  : Colors.transparent,
              child: bar,
            ),
          ),
        ),
      ),
    );
  }
}

/// Translucent overlay covering the half of the pane toward [edge], showing
/// where a dropped pane will re-dock.
class _DropHighlight extends StatelessWidget {
  const _DropHighlight({required this.edge});

  final DropEdge edge;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary.withValues(alpha: 0.25);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final rect = switch (edge) {
          DropEdge.left => Rect.fromLTWH(0, 0, w / 2, h),
          DropEdge.right => Rect.fromLTWH(w / 2, 0, w / 2, h),
          DropEdge.top => Rect.fromLTWH(0, 0, w, h / 2),
          DropEdge.bottom => Rect.fromLTWH(0, h / 2, w, h / 2),
        };
        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(child: ColoredBox(color: color)),
            ),
          ],
        );
      },
    );
  }
}
