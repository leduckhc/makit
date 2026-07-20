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
    final cs = Theme.of(context).colorScheme;
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
        child: SizedBox(
          width: 8,
          height: double.infinity,
          child: Column(
            children: [
              // Fill the title-bar row so the top band is continuous with the
              // sidebar header and the pane title (all surfaceContainer) — no
              // gap between the two coloured bands.
              Container(height: kTitleBarStripHeight, color: cs.surfaceContainer),
              // Titlebar bottom border across the handle, connecting the
              // sidebar header's hairline to the pane title strip's (no gap).
              const Divider(height: 1),
              // Below the band: hairline flush against the sidebar's edge; the
              // rest of the grab strip stays transparent (chat bg) so no gap
              // shows on the sidebar.
              const Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: VerticalDivider(width: 1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
