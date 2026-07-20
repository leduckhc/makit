import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../../store/models.dart';
import '../../../store/store.dart';
import '../../../ui/composer/client_commands.dart';
import '../selected_session.dart';
import '../sidebar_layout.dart';
import '../title_bar_strip.dart';
import 'pane_tree_controller.dart';

/// The docked pane header: the session title, the sidebar-unfold control when
/// collapsed, and the session actions menu (SPEC-19, moved from
/// desktop_chat_pane). Sits on the traffic-light row and keeps the window
/// draggable where the sidebar's drag strip used to be.
class PaneHeader extends ConsumerWidget {
  const PaneHeader({
    super.key,
    required this.session,
    required this.fallbackId,
  });
  final Session? session;
  final String fallbackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(sidebarCollapsedProvider);
    // Same fallback order as the sidebar tiles (SPEC-12 decision 8):
    // title → agent name → raw session id.
    final title = sessionPaneTitle(session, fallbackId);
    final theme = Theme.of(context);
    final content = Padding(
      // When collapsed the pane starts at window x=0, so inset the leading
      // control past the traffic lights and align it to the traffic-light row;
      // otherwise use the normal gutter.
      padding: EdgeInsets.fromLTRB(
        collapsed ? kTrafficLightInset : 16,
        7,
        16,
        12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (collapsed) ...[
            const SidebarToggleButton(collapse: false),
            const SizedBox(width: 8),
          ],
          if (session != null) ...[
            // Match the sidebar-fold icon scale so the fold icon,
            // title, and actions menu all sit on the traffic-light row.
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: 4),
          SessionActionsMenu(sessionId: fallbackId),
        ],
      ),
    );
    // Keep the window draggable where the sidebar's drag strip used to be.
    // DragToMoveArea sits UNDER the content (Stack sibling, like the sidebar's
    // _Header) rather than wrapping it: its double-tap recognizer would
    // otherwise delay every button tap by the gesture-disambiguation window.
    if (!collapsed) return content;
    return Stack(
      children: [
        const Positioned.fill(child: DragToMoveArea(child: SizedBox.expand())),
        content,
      ],
    );
  }
}

/// The session name shown in a pane header: title, else agent name, else id.
String sessionPaneTitle(Session? session, String fallbackId) {
  if (session != null && session.title.trim().isNotEmpty) {
    return session.title.trim();
  }
  if (session != null && session.agent.trim().isNotEmpty) return session.agent;
  return fallbackId;
}

/// The session-level overflow menu (Rename / Quit) for a pane header. Model and
/// thinking-effort live inline in the composer footer, so they are not repeated
/// here. Shared by the docked [PaneHeader] and the split pane tree's tab strip.
class SessionActionsMenu extends ConsumerWidget {
  /// Creates the actions menu acting on [sessionId]. [leafId] is the pane leaf
  /// hosting the menu; when provided, "Quit session" also closes that pane
  /// (Quit = kill the session **and** close its pane). Null keeps the plain
  /// unbind behaviour (the standalone [PaneHeader], not used in the pane tree).
  const SessionActionsMenu({super.key, required this.sessionId, this.leafId});

  /// The session the menu's actions target.
  final String sessionId;

  /// The pane leaf hosting this menu, closed on Quit when non-null.
  final String? leafId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Session actions',
      padding: EdgeInsets.zero,
      // Use `child` (not `icon`): `icon` builds an internal IconButton that
      // enforces a 48px min tap target, which inflates the header row and
      // pushes the centered row content below the traffic-light line.
      child: const Padding(
        padding: EdgeInsets.all(3),
        child: Icon(PhosphorIconsLight.dotsThree, size: 18),
      ),
      onSelected: (value) {
        switch (value) {
          case 'rename':
            handleClientCommand(
              '/name',
              context: context,
              ref: ref,
              sessionId: sessionId,
            );
          case 'quit':
            _confirmQuit(context, ref);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'rename',
          child: ListTile(
            leading: Icon(PhosphorIconsLight.pencilSimple),
            title: Text('Rename session'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'quit',
          child: ListTile(
            leading: Icon(PhosphorIconsLight.power),
            title: Text('Quit session'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmQuit(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Quit session?'),
        content: const Text(
          'This stops the agent process and removes the session. '
          'The transcript stays on disk and can be re-attached later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Quit'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // Capture notifiers before the async gap: the optimistic close disposes
    // this menu's widget, so nothing below may touch `ref`/`context`.
    final store = ref.read(storeControllerProvider.notifier);
    final panes = ref.read(paneTreeControllerProvider.notifier);
    final selection = ref.read(selectedSessionProvider.notifier);

    // Optimistic: close the pane now, don't wait on the server. Quit = close
    // this pane + kill the session. Closing the last pane clears the tree to
    // the empty placeholder; a split collapses into its sibling.
    if (leafId != null) {
      panes.setActive(leafId!);
      panes.closeActive();
    }
    // Drop any *other* panes still bound to the session so it never lingers in
    // another worktree's layout, and clear the sidebar highlight if it still
    // points here (never stomp a selection the user has since moved elsewhere).
    panes.unbindSession(sessionId);
    if (selection.state == sessionId) {
      selection.state = null;
    }

    // Fire the kill in the background. The sidebar reconciles from server
    // snapshots, so on failure the session simply stays/reappears there; just
    // surface the error.
    try {
      await store.killSession(sessionId);
    } catch (e) {
      if (messenger.mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Could not quit: $e')));
      }
    }
  }
}

/// A slim top strip shown above the pane's empty state when the sidebar is
/// hidden, so the unfold control stays reachable with no session selected.
/// Renders nothing while the sidebar is visible. Mirrors the sidebar's
/// `_Header` drag-strip + overlaid fold button.
class UnfoldStrip extends ConsumerWidget {
  const UnfoldStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(sidebarCollapsedProvider)) return const SizedBox.shrink();
    return const TitleBarStrip(leading: SidebarToggleButton(collapse: false));
  }
}
