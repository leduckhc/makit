import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_sidebar.dart';
import 'panes/pane_tree_view.dart';
import 'sidebar_layout.dart';

/// The desktop chat surface: a foldable, resizable [DesktopSidebar] on the left
/// and the [DesktopChatPane] filling the rest. This is the primary window of
/// the desktop app (Unit E wires it into `runDesktopApp`).
class DesktopChatShell extends ConsumerWidget {
  /// Creates the two-pane chat shell.
  const DesktopChatShell({super.key, this.onOpenSettings});

  /// Forwarded to the sidebar footer to open the Settings/Server section.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(sidebarCollapsedProvider);
    final width = ref.watch(sidebarWidthProvider);

    return Scaffold(
      body: Row(
        children: [
          if (!collapsed) ...[
            SizedBox(
              width: width,
              child: DesktopSidebar(onOpenSettings: onOpenSettings),
            ),
            const _SidebarResizeHandle(),
          ],
          const Expanded(child: PaneTreeView()),
        ],
      ),
    );
  }
}

/// A thin draggable strip that doubles as the sidebar/pane divider. Dragging it
/// resizes the sidebar within [kSidebarMinWidth]–[kSidebarMaxWidth].
class _SidebarResizeHandle extends ConsumerWidget {
  const _SidebarResizeHandle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) {
          ref
              .read(sidebarWidthProvider.notifier)
              .update(
                (w) => (w + details.delta.dx).clamp(
                  kSidebarMinWidth,
                  kSidebarMaxWidth,
                ),
              );
        },
        child: const SizedBox(
          width: 8,
          height: double.infinity,
          child: Center(child: VerticalDivider(width: 1)),
        ),
      ),
    );
  }
}
