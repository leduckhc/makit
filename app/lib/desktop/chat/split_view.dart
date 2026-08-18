import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import '../../store/store.dart';
import '../../ui/composer/client_commands.dart';
import '../../ui/session/session_identity.dart';
import '../../ui/widgets/menu_item.dart';
import 'desktop_chat_pane.dart';
import 'groups/agent_picker.dart';
import 'groups/group.dart';
import 'groups/group_providers.dart';
import 'groups/groups_controller.dart';
import 'panes/split_node.dart';
import 'panes/workspace_controller.dart';
import 'selected_session.dart';
import '../../ui/widgets/session_status_dot.dart';

/// Height of a [Split]'s tab strip.
const double _kTabBarHeight = 30;

/// The flat body background for a pane. The focused pane sits one tonal step up
/// the neutral ramp (lighter in *both* themes — Material treats elevated
/// surfaces as lighter, so "lighter = active" holds in dark mode too); the
/// unfocused panes recede to the base [ColorScheme.surface]. Subtle by design:
/// one ramp step, so it dims focus context without dimming chat legibility.
Color _paneBackground(ColorScheme cs, {required bool focused}) {
  if (cs.brightness == Brightness.dark) {
    return focused ? cs.surfaceContainerLow : cs.surface;
  }
  return focused ? cs.surface : cs.surfaceContainerLow;
}

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

/// What a drop converted, when it did: the worktree group's label and the board
/// that replaced it on the canvas.
typedef GroupConversion = ({String from, String to});

/// Registers [sessionId] in the active group and puts it on the canvas
/// (decision 14), returning a [GroupConversion] when the add converted a
/// worktree group into a board (decision 4) and null otherwise.
///
/// Extracted from the drag target so the orchestration is testable directly: a
/// simulated `Draggable`→`DragTarget` accept does not fire reliably in the test
/// harness, and this is the load-bearing part — after a conversion the derived
/// `workspaceControllerProvider` has been rebuilt against the new board's tree,
/// so the reveal must go through a freshly read controller, not the one the
/// caller was holding.
GroupConversion? dropSessionIntoActiveGroup(
  WidgetRef ref, {
  required String sessionId,
  required String splitId,
  required DropEdge? zone,
  required WorkspaceController controller,
}) {
  final active = ref.read(groupsControllerProvider).active;
  final session = ref.read(sessionsProvider).byId(sessionId);
  // The session can be closed between the drag starting and the drop landing.
  // There is then nothing to add and nothing to show: opening a tab for it would
  // put a pane on the canvas bound to a session the server no longer has, which
  // is the dead tile decision 6 forbids.
  if (session == null) return null;
  ref
      .read(groupsControllerProvider.notifier)
      .addMember(active.id, sessionId, location: locationOf(session));
  final afterActive = ref.read(groupsControllerProvider).active;
  if (afterActive.id != active.id) {
    ref.read(workspaceControllerProvider.notifier).revealSession(sessionId);
    return (from: active.label, to: afterActive.label);
  }
  if (zone == null) {
    controller.openSessionInSplit(splitId, sessionId);
  } else {
    controller.openSessionAtEdge(splitId, sessionId, zone);
  }
  return null;
}

/// Renders a single [Split]: a tab strip (its tabs in order, active
/// highlighted, per-tab close ✕, a group-aware `+` — the in-pane starter in a
/// worktree group, the agent picker on a board) above
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

  /// A session dropped from the sidebar (decision 14). Delegates the
  /// orchestration to [dropSessionIntoActiveGroup] so it is reachable without a
  /// simulated drag gesture, and announces a conversion here (a silent canvas
  /// swap would be a surprise).
  void _dropSession(
    WorkspaceController controller,
    String sessionId,
    DropEdge? zone,
  ) {
    final conversion = dropSessionIntoActiveGroup(
      ref,
      sessionId: sessionId,
      splitId: widget.split.id,
      zone: zone,
      controller: controller,
    );
    if (conversion != null) {
      _announceConversion(conversion.from, conversion.to);
    }
  }

  /// Tells the user an explicit add converted a worktree group into a board —
  /// the original group is untouched and still reachable from the sidebar
  /// (decision 4).
  void _announceConversion(String fromLabel, String boardLabel) {
    ref.status.info(
      '“$fromLabel” only holds its own branch, so this add made the board '
      '“$boardLabel”',
      source: StatusSources.worktree,
      detail:
          'The worktree group is untouched — click it in the sidebar to get '
          'it back.',
    );
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
          _dropSession(controller, data.sessionId, zone);
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
            // Focused pane sits one tonal step lighter; unfocused panes recede
            // so the active pane reads as "in focus" (the tab bar keeps its own
            // recessed colour on top of this).
            color: _paneBackground(
              Theme.of(context).colorScheme,
              focused: widget.active,
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Column(
                    children: [
                      _TabBar(split: widget.split, active: widget.active),
                      Expanded(
                        child: DesktopChatPane(
                          // Key by the active tab so switching tabs recreates
                          // the pane state (composer draft is re-seeded).
                          key: ValueKey(active.id),
                          sessionId: active.sessionId,
                          worktree: active.worktree,
                          showHeader: false,
                          composerFocusId: active.id,
                          composerExpanded: widget.active,
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
/// button opening the in-pane starter (worktree group) or the agent picker
/// (board).
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
                            splitActive: active,
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 24,
                  ),
                  // Group-dependent, matching the approved mock: a worktree
                  // group's + starts an agent on that branch, a board's + adds
                  // one to the board. "New session" described neither.
                  tooltip:
                      ref.watch(activeGroupProvider).kind == GroupKind.board
                      ? 'Add an agent to this board'
                      : 'New agent on this branch',
                  color: cs.onSurface,
                  icon: const Icon(PhosphorIconsLight.plus),
                  onPressed: () => _onAddPressed(context, ref),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The tab-strip `+` is group-aware (decision 13). On a **board** it opens
  /// the agent picker (there is no scope, so it asks "which agent?"). In a
  /// **worktree group** the branch already answers "where does it run?", so it
  /// opens the in-pane starter by adding a fresh tab hinted with the group's
  /// scope — **never the dialog**.
  void _onAddPressed(BuildContext context, WidgetRef ref) {
    final controller = ref.read(workspaceControllerProvider.notifier);
    controller.setActiveSplit(split.id);
    final group = ref.read(activeGroupProvider);
    if (group.kind == GroupKind.board) {
      showAgentPicker(context, ref);
      return;
    }
    // A worktree group without a scope cannot exist — `Group.worktree` requires
    // both halves and the decoder drops an entry missing either — so this is an
    // invariant, not a UX branch. Asserting says so instead of implying the
    // dialog is a legitimate outcome here (decision 13 says it never is).
    final hint = _groupWorktreeHint(group);
    // A worktree group always carries both halves (Group.worktree requires them
    // and the decoder drops an entry missing either), so the hint is never null
    // here — assert the invariant rather than crash on a bare `!` if it is.
    assert(hint != null, 'a worktree group must carry its scope');
    controller.openTab(
      split.id,
      Tab(id: nextNodeId(SplitNodeKind.tab), worktree: hint),
    );
  }
}

/// The scope of a worktree [group] as a tab hint. Null only for a board, which
/// owns no scope — a *worktree* group always carries both halves.
SelectedWorktree? _groupWorktreeHint(Group group) {
  final projectId = group.projectId;
  final path = group.worktreePath;
  if (projectId == null || path == null) return null;
  return SelectedWorktree(
    projectId: projectId,
    path: path,
    branch: group.label,
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
    required this.splitActive,
  });

  final Split split;
  final Tab tab;
  final int index;

  /// This tab is the selected tab within its split.
  final bool active;

  /// This tab's split is the focused split. Only the selected tab of the
  /// focused split gets the green cap; every other tab's cap is a dim neutral.
  final bool splitActive;

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

    // The active tab is its pane's own body surface, rounded on the TOP only and
    // with nothing drawn between it and the body beneath (no cap, no divider),
    // so the tab and its content read as one cohesive shape. Which split is
    // focused is shown by the pane's tonal step (a focused pane, and thus its
    // active tab, sits one step lighter) — not by a stripe on the tab.
    final chip = ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
      child: Container(
        constraints: const BoxConstraints(minWidth: 96, maxWidth: 220),
        color: active
            ? _paneBackground(cs, focused: splitActive)
            : Colors.transparent,
        padding: const EdgeInsets.only(left: 10, right: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (session != null) ...[
              SessionStatusDot(status: session.status),
              const SizedBox(width: kSpace6),
            ],
            Expanded(
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
            IconButton(
              iconSize: 12,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              tooltip: 'Close tab',
              color: active ? cs.onSurface : cs.onSurfaceVariant,
              icon: const Icon(PhosphorIconsLight.x),
              onPressed: () =>
                  closeTabAndSession(ref, split.id, tab.id, tab.sessionId),
            ),
          ],
        ),
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
          // Anchor the feedback to the POINTER, so `DragTargetDetails.offset`
          // (which is the feedback's top-left) is the cursor. The drop-zone maths
          // in `_tabZoneFor` treats that offset as the cursor, so with the
          // default anchor the zone depended on the chip's width — i.e. on the
          // session's TITLE LENGTH: dragging a long-titled tab onto a pane's
          // centre could land in an edge zone and split instead of moving.
          dragAnchorStrategy: pointerDragAnchorStrategy,
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
              // Right-click (desktop) / long-press (touch) opens the tab
              // context menu. Only a real session can be renamed, so the
              // menu is suppressed for the empty "New" tab.
              onSecondaryTapDown: sessionId == null
                  ? null
                  : (d) => _showContextMenu(
                      context,
                      ref,
                      d.globalPosition,
                      sessionId,
                    ),
              onLongPressStart: sessionId == null
                  ? null
                  : (d) => _showContextMenu(
                      context,
                      ref,
                      d.globalPosition,
                      sessionId,
                    ),
              // Inactive tabs are dimmed so only the active tab reads at full
              // strength (its green status dot / label stands out); inactive
              // tabs recede as muted context.
              child: active ? chip : Opacity(opacity: 0.55, child: chip),
            ),
          ),
        );
      },
    );
  }

  /// Tab context menu (right-click / long-press): **Rename session** and
  /// **Copy session id**. Deliberately NOT a *Session details…* item (D13): a
  /// third door onto the same sheet, one pixel from the pane-header kebab on the
  /// same platform, was cut on review. **Copy session id** stays because it is a
  /// different job — right-click → one click → the bare id, no dialog.
  Future<void> _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    Offset globalPosition,
    String sessionId,
  ) async {
    final overlayState = Navigator.of(context).overlay;
    if (overlayState == null) return;
    final overlayBox = overlayState.context.findRenderObject();
    if (overlayBox is! RenderBox) return;
    // Resolved before the `showMenu` await (SPEC-status-and-activity D3): `ref` dies with its
    // widget, and the copy path reports its outcome after an await.
    final status = ref.status;
    // The identity is hoisted for the SAME reason, and it is not optional care:
    // this menu lives in the Navigator's overlay, so it outlives the tab chip
    // that opened it. Close the tab while the menu is open — a server snapshot
    // dropping the session does it for real — and a `ref.read` down in the
    // `copyId` branch would run on a dead `ref` and throw `Cannot use "ref"
    // after the widget was disposed`, i.e. crash instead of copying.
    //
    // The cost is that the id is sampled at menu-open rather than at click. That
    // is sub-second for a right-click → click, and it is the RIGHT trade here:
    // the live-filling surface is the panel, which watches (D19). Rejected
    // alternative: guarding the late read with `context.mounted`, which keeps the
    // read fresh but leaves `ref` use after an await — the hazard SPEC-status-and-activity D3
    // exists to remove.
    final identity = ref.read(sessionIdentityProvider(sessionId));
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlayBox.size,
      ),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        themedMenuItem(
          value: 'rename',
          icon: PhosphorIconsLight.pencilSimple,
          label: 'Rename session',
        ),
        themedMenuItem(
          value: 'copyId',
          icon: PhosphorIconsLight.copy,
          label: 'Copy session id',
        ),
      ],
    );
    if (selected == 'copyId') {
      // The BARE agent session id (D6), not `sessionIdentityText` — that whole
      // label:value payload is `Copy all`'s job in the panel. No dialog.
      final id = identity.agentSessionId;
      if (id == null) {
        status.warning(
          'No agent session id yet',
          source: StatusSources.session,
          sessionId: sessionId,
        );
        return;
      }
      // A clipboard write can throw for real (another process holds it on
      // Windows; the host denies it). Unreported, the user gets neither the id
      // nor a reason. Same contract as the panel's `Copy all` and `/session id`.
      try {
        await Clipboard.setData(ClipboardData(text: id));
      } catch (e) {
        status.failure(
          'Could not copy session id',
          error: e,
          source: StatusSources.session,
          sessionId: sessionId,
        );
        return;
      }
      status.info(
        'Session id copied',
        source: StatusSources.session,
        detail: id,
        sessionId: sessionId,
      );
      return;
    }
    if (selected != 'rename' || !context.mounted) return;
    await handleClientCommand(
      '/name',
      context: context,
      ref: ref,
      sessionId: sessionId,
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
