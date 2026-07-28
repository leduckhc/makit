import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/store.dart';
import 'desktop_chat_pane.dart';
import 'new_session_dialog.dart';
import 'panes/split_node.dart';
import 'panes/workspace_controller.dart';
import 'selected_session.dart';
import 'session_status_dot.dart';

/// Height of a [Split]'s tab strip.
const double _kTabBarHeight = 30;

/// A dragged tab: which [Split] and [Tab] it came from, so a drop can reorder
/// within the bar or move it to another bar (`WorkspaceController.moveTab`).
@immutable
class TabDragData {
  /// Creates the drag payload.
  const TabDragData({required this.fromSplitId, required this.tabId});

  /// The split the tab is being dragged out of.
  final String fromSplitId;

  /// The tab being dragged.
  final String tabId;
}

/// A dragged [Split]: which split is being re-docked (`moveSplit`).
@immutable
class SplitDragData {
  /// Creates the drag payload.
  const SplitDragData(this.splitId);

  /// The split being dragged onto another split's [DropEdge].
  final String splitId;
}

/// A session dragged from the sidebar onto a pane: dropped into a group
/// (centre / tab strip) or a new split (edge). See [SessionDragData] handling
/// in [SplitView].
@immutable
class SessionDragData {
  /// Creates the drag payload.
  const SessionDragData(this.sessionId);

  /// The session being dragged in from the sidebar.
  final String sessionId;
}

/// Renders a single [Split]: a tab strip (its tabs in order, active
/// highlighted, per-tab close ✕, a `+` opening the New session dialog) above
/// the active tab's body. The region is a [DragTarget] for split re-docking
/// (drop on a [DropEdge]); each tab is draggable within/between bars.
class SplitView extends ConsumerStatefulWidget {
  /// Creates the split view for [split]; [active] draws the focused affordance.
  const SplitView({super.key, required this.split, required this.active});

  /// The split to render.
  final Split split;

  /// Whether this is the workspace's active split.
  final bool active;

  @override
  ConsumerState<SplitView> createState() => _SplitViewState();
}

class _SplitViewState extends ConsumerState<SplitView> {
  final _key = GlobalKey();
  DropEdge? _hoverEdge;
  // True while a *tab* is hovering the pane's centre zone (drop = move the tab
  // into this group). Edge zones set [_hoverEdge] instead (drop = new split).
  bool _hoverTabCentre = false;

  /// The drop edge nearest [global] (a [DragTargetDetails.offset]). The same
  /// offset drives both the hover highlight and the accept, so they always
  /// agree.
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

  /// The drop zone for a *tab* dropped at [global]. VSCode-style:
  ///  - anywhere on the tab strip, or the body's centre dead-zone (inner half)
  ///    → null (move the tab into this group);
  ///  - near a body edge → that edge (detach into a new split on that side).
  DropEdge? _tabZoneFor(Offset global) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    final size = box.size;
    // Anywhere on the tab strip means "add to this group". Dropping on a
    // specific tab is handled by that chip's own DragTarget, which sits in
    // front and wins the drop for precise index insertion.
    if (local.dy <= _kTabBarHeight) return null;
    final dx = (local.dx / size.width).clamp(0.0, 1.0);
    final dy = (local.dy / size.height).clamp(0.0, 1.0);
    if ((dx - 0.5).abs() < 0.25 && (dy - 0.5).abs() < 0.25) return null;
    return _edgeFor(global);
  }

  Tab _activeTab() {
    final split = widget.split;
    for (final t in split.tabs) {
      if (t.id == split.activeTabId) return t;
    }
    return split.tabs.first;
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(workspaceControllerProvider.notifier);
    final active = _activeTab();
    return DragTarget<Object>(
      onWillAcceptWithDetails: (details) {
        final data = details.data;
        if (data is SplitDragData) {
          if (data.splitId == widget.split.id) return false;
          setState(() {
            _hoverEdge = _edgeFor(details.offset);
            _hoverTabCentre = false;
          });
          return true;
        }
        if (data is TabDragData || data is SessionDragData) {
          final zone = _tabZoneFor(details.offset);
          setState(() {
            _hoverEdge = zone;
            _hoverTabCentre = zone == null;
          });
          return true;
        }
        return false;
      },
      onMove: (details) {
        final data = details.data;
        if (data is SplitDragData) {
          if (data.splitId == widget.split.id) return;
          final edge = _edgeFor(details.offset);
          if (edge != _hoverEdge || _hoverTabCentre) {
            setState(() {
              _hoverEdge = edge;
              _hoverTabCentre = false;
            });
          }
        } else if (data is TabDragData || data is SessionDragData) {
          final zone = _tabZoneFor(details.offset);
          if (zone != _hoverEdge || (zone == null) != _hoverTabCentre) {
            setState(() {
              _hoverEdge = zone;
              _hoverTabCentre = zone == null;
            });
          }
        }
      },
      onLeave: (_) => setState(() {
        _hoverEdge = null;
        _hoverTabCentre = false;
      }),
      onAcceptWithDetails: (details) {
        final data = details.data;
        if (data is SplitDragData) {
          final edge = _edgeFor(details.offset);
          setState(() {
            _hoverEdge = null;
            _hoverTabCentre = false;
          });
          controller.moveSplit(data.splitId, widget.split.id, edge);
          return;
        }
        if (data is TabDragData) {
          final zone = _tabZoneFor(details.offset);
          setState(() {
            _hoverEdge = null;
            _hoverTabCentre = false;
          });
          if (zone == null) {
            // Centre → move the tab into this group (append after its tabs).
            controller.moveTab(
              data.fromSplitId,
              data.tabId,
              widget.split.id,
              widget.split.tabs.length,
            );
          } else {
            controller.moveTabToEdge(
              data.fromSplitId,
              data.tabId,
              widget.split.id,
              zone,
            );
          }
          return;
        }
        if (data is SessionDragData) {
          final zone = _tabZoneFor(details.offset);
          setState(() {
            _hoverEdge = null;
            _hoverTabCentre = false;
          });
          if (zone == null) {
            controller.openSessionInSplit(widget.split.id, data.sessionId);
          } else {
            controller.openSessionAtEdge(widget.split.id, data.sessionId, zone);
          }
        }
      },
      builder: (context, candidate, rejected) {
        // Listener (not GestureDetector) so pointer-down activates the split
        // even when the click lands on an inner tappable widget (the composer
        // field, buttons…) that would otherwise win the gesture arena.
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => controller.setActiveSplit(widget.split.id),
          child: Container(
            key: _key,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Column(
                    children: [
                      _TabBar(split: widget.split, active: widget.active),
                      const Divider(height: 1),
                      Expanded(
                        child: DesktopChatPane(
                          // Key by the active tab so switching tabs recreates
                          // the pane state (composer draft is re-seeded).
                          key: ValueKey(active.id),
                          sessionId: active.sessionId,
                          worktree: active.worktree,
                          showHeader: false,
                          composerFocusId: active.id,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_hoverTabCentre)
                  const Positioned.fill(child: _DropHighlight())
                else if (_hoverEdge != null)
                  Positioned.fill(child: _DropHighlight(edge: _hoverEdge!)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The tab strip: a draggable-to-move-split grip, the tabs in order, and a `+`
/// button opening the New session dialog (pre-filled with the active tab's
/// worktree when known).
class _TabBar extends ConsumerWidget {
  const _TabBar({required this.split, required this.active});

  final Split split;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: _kTabBarHeight,
      color: cs.surfaceContainerLow,
      child: Stack(
        children: [
          // The empty header area is the split's drag handle (VSCode-style):
          // grab anywhere without a tab/button to re-dock the whole split.
          Positioned.fill(child: _SplitHeaderDragHandle(split: split)),
          // Fill the bar's full height so tab chips stretch edge-to-edge (the
          // active chip's surface then seats flush against the top/bottom with
          // no recessed-bar gap); a bare Row would only take its intrinsic
          // height and float centred, leaving a gap above/below the chips.
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < split.tabs.length; i++)
                        _TabChip(
                          key: ValueKey(split.tabs[i].id),
                          split: split,
                          tab: split.tabs[i],
                          index: i,
                          active: split.tabs[i].id == split.activeTabId,
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
                tooltip: 'New session',
                color: cs.onSurfaceVariant,
                icon: const Icon(PhosphorIconsLight.plus),
                onPressed: () {
                  ref
                      .read(workspaceControllerProvider.notifier)
                      .setActiveSplit(split.id);
                  final worktree = _prefillWorktree(ref, split);
                  showNewSessionDialog(
                    context,
                    ref,
                    projectId: worktree?.projectId,
                    worktree: worktree,
                  );
                },
              ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The active tab's real worktree (for pre-filling the New session dialog), or
/// null when it has no session on disk yet. An empty tab's worktree hint
/// pre-fills too.
SelectedWorktree? _prefillWorktree(WidgetRef ref, Split split) {
  Tab? active;
  for (final t in split.tabs) {
    if (t.id == split.activeTabId) active = t;
  }
  if (active == null) return null;
  final sessionId = active.sessionId;
  if (sessionId == null) return active.worktree;
  final session = ref.read(sessionsProvider).byId(sessionId);
  final path = session?.worktreePath;
  if (session == null || path == null) return null;
  return SelectedWorktree(
    projectId: session.projectId,
    path: path,
    branch: session.branch,
  );
}

/// The empty tab-bar header area, draggable to re-dock the whole split to
/// another split's edge (VSCode-style: grab where there are no tabs). Fills the
/// space behind the tab row via [Positioned.fill]; tabs/buttons sit on top and
/// win hit-testing, so only the empty region initiates a split move.
class _SplitHeaderDragHandle extends ConsumerWidget {
  const _SplitHeaderDragHandle({required this.split});

  final Split split;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Draggable<SplitDragData>(
      data: SplitDragData(split.id),
      hitTestBehavior: HitTestBehavior.opaque,
      onDragStarted: () => ref
          .read(workspaceControllerProvider.notifier)
          .setActiveSplit(split.id),
      // No visible drag avatar — the target pane's drop highlight is the only
      // affordance (a floating tab-sized chip read as a stray tab).
      feedback: const SizedBox.shrink(),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Semantics(
          label: 'Move split',
          button: true,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// One tab: its label + status dot + close ✕, draggable to reorder or move to
/// another split, and a [DragTarget] so a tab dropped on it inserts at its
/// index (`moveTab`).
class _TabChip extends ConsumerWidget {
  const _TabChip({
    super.key,
    required this.split,
    required this.tab,
    required this.index,
    required this.active,
  });

  final Split split;
  final Tab tab;
  final int index;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final controller = ref.read(workspaceControllerProvider.notifier);
    final sessionId = tab.sessionId;
    final session = sessionId == null
        ? null
        : ref.watch(sessionsProvider).byId(sessionId);
    final label = sessionId == null
        ? 'New'
        : sessionPaneTitle(session, sessionId);

    final chip = Container(
      constraints: const BoxConstraints(minWidth: 96, maxWidth: 220),
      padding: const EdgeInsets.only(left: 10, right: 4),
      decoration: BoxDecoration(
        // Active tab uses the pane's own surface so it "seats" into the body
        // below; a 2px primary cap marks it. Inactive tabs are flush and
        // transparent (reading the recessed bar). Right divider separates tabs.
        color: active ? cs.surface : Colors.transparent,
        border: Border(
          top: BorderSide(
            color: active ? cs.primary : Colors.transparent,
            width: 2,
          ),
          right: BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (session != null) ...[
            SessionStatusDot(status: session.status),
            const SizedBox(width: kSpace6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
                color: active ? cs.onSurface : cs.onSurfaceVariant,
              ),
            ),
          ),
          if (sessionId != null)
            SessionActionsMenu(
              sessionId: sessionId,
              splitId: split.id,
              tabId: tab.id,
            ),
          IconButton(
            iconSize: 12,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            tooltip: 'Close tab',
            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
            icon: const Icon(PhosphorIconsLight.x),
            onPressed: () =>
                closeTabAndArchive(ref, split.id, tab.id, tab.sessionId),
          ),
        ],
      ),
    );

    return DragTarget<TabDragData>(
      onWillAcceptWithDetails: (details) =>
          details.data.tabId != tab.id || details.data.fromSplitId != split.id,
      onAcceptWithDetails: (details) => controller.moveTab(
        details.data.fromSplitId,
        details.data.tabId,
        split.id,
        index,
      ),
      builder: (context, candidate, rejected) {
        return Draggable<TabDragData>(
          data: TabDragData(fromSplitId: split.id, tabId: tab.id),
          onDragStarted: () => controller.setActiveTab(split.id, tab.id),
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(opacity: 0.9, child: chip),
          ),
          childWhenDragging: Opacity(opacity: 0.4, child: chip),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => controller.setActiveTab(split.id, tab.id),
              // Inactive tabs are dimmed so only the active tab reads at full
              // strength (its green status dot / label stands out); inactive
              // tabs recede as muted context.
              child: active
                  ? chip
                  : Opacity(opacity: 0.55, child: chip),
            ),
          ),
        );
      },
    );
  }
}

/// Translucent overlay showing where a drop will land: half the pane toward
/// [edge] for an edge dock (split re-dock or tab detach), or the whole pane
/// when [edge] is null (a tab dropped in the centre → move into this group).
class _DropHighlight extends StatelessWidget {
  const _DropHighlight({this.edge});

  final DropEdge? edge;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary.withValues(alpha: 0.25);
    final edge = this.edge;
    if (edge == null) {
      return IgnorePointer(child: ColoredBox(color: color));
    }
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
