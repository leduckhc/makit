import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../../app/theme.dart';
import '../../../store/models.dart';
import '../../../store/store.dart';
import '../../../ui/composer/client_commands.dart';
import '../sidebar_layout.dart';
import '../title_bar_strip.dart';
import 'workspace_controller.dart';

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
            const SizedBox(width: kSpace8),
          ],
          if (session != null) ...[
            // Match the sidebar-fold icon scale so the fold icon,
            // title, and actions menu all sit on the traffic-light row.
            const SizedBox(width: kSpace10),
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
          const SizedBox(width: kSpace4),
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

/// The session-level overflow menu (Rename / Quit) for a tab strip. Model and
/// thinking-effort live inline in the composer footer, so they are not repeated
/// here. Shared by the docked [PaneHeader] and the workspace tab strip.
class SessionActionsMenu extends ConsumerWidget {
  /// Creates the actions menu acting on [sessionId]. [splitId]/[tabId] identify
  /// the tab hosting the menu; when both are provided, "Quit session" also
  /// closes that tab (Quit = kill the session **and** close its tab). Null
  /// keeps the plain unbind behaviour (the standalone [PaneHeader], not used in
  /// the workspace tree).
  const SessionActionsMenu({
    super.key,
    required this.sessionId,
    this.splitId,
    this.tabId,
  });

  /// The session the menu's actions target.
  final String sessionId;

  /// The split hosting this menu's tab, closed on Quit when non-null.
  final String? splitId;

  /// The tab hosting this menu, closed on Quit when non-null.
  final String? tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Session actions',
      popUpAnimationStyle: AnimationStyle.noAnimation,
      padding: EdgeInsets.zero,
      // Use `child` (not `icon`): `icon` builds an internal IconButton that
      // enforces a 48px min tap target, which inflates the header row and
      // pushes the centered row content below the traffic-light line.
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(
          PhosphorIconsRegular.dotsThree,
          size: 20,
          color: Theme.of(context).colorScheme.onSurface,
        ),
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
            _confirmArchive(context, ref);
        }
      },
      itemBuilder: (context) {
        final cs = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        return [
          PopupMenuItem(
            value: 'rename',
            height: 36,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  PhosphorIconsLight.pencilSimple,
                  size: 16,
                  color: cs.onSurface,
                ),
                const SizedBox(width: kSpace8),
                Flexible(
                  child: Text('Rename session', style: textTheme.bodyMedium),
                ),
              ],
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'quit',
            height: 36,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  PhosphorIconsLight.archiveBox,
                  size: 16,
                  color: cs.onSurface,
                ),
                const SizedBox(width: kSpace8),
                Flexible(
                  child: Text('Archive session', style: textTheme.bodyMedium),
                ),
              ],
            ),
          ),
        ];
      },
    );
  }

  Future<void> _confirmArchive(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Archive session?'),
        content: const Text(
          'This removes the session from the active list and stops its agent. '
          'The transcript is kept and the session can be restored later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // Capture notifiers before the async gap: the optimistic close disposes
    // this menu's widget, so nothing below may touch `ref`/`context`.
    final store = ref.read(storeControllerProvider.notifier);
    final workspace = ref.read(workspaceControllerProvider.notifier);

    // Archive first, then drop the session's tabs — only mutate the workspace
    // once the archive is acknowledged, so a failed archive leaves the active
    // session and its tabs intact (no orphaned layout).
    try {
      await store.archiveSession(sessionId);
      if (splitId != null && tabId != null) {
        workspace.closeTab(splitId!, tabId!);
      }
      // Drop any *other* tab still hosting the session so it never lingers.
      workspace.unbindSession(sessionId);
    } catch (e) {
      if (messenger.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Could not archive: $e')),
        );
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
