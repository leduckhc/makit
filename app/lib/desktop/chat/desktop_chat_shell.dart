import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_sidebar.dart';
import 'split_tree_view.dart';
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

    if (collapsed) {
      return const Scaffold(body: WorkspaceView());
    }
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              SizedBox(
                width: width,
                child: DesktopSidebar(onOpenSettings: onOpenSettings),
              ),
              // 1px hairline flush against the sidebar; the panes abut it
              // directly so there's no gap between the sidebar and pane A.
              const _SidebarDivider(),
              const Expanded(child: WorkspaceView()),
            ],
          ),
          // The resize strip is overlaid on the sidebar|pane seam (straddling
          // it) rather than occupying layout width — which would push the panes
          // right and leave an empty gap between the sidebar and pane A.
          Positioned(
            left: width - 4,
            top: 0,
            bottom: 0,
            width: 8,
            child: const _SidebarResizeHandle(),
          ),
        ],
      ),
    );
  }
}

/// The 1px hairline between the sidebar and the pane area, flush against the
/// sidebar's edge so the leftmost pane seats directly against it.
class _SidebarDivider extends StatelessWidget {
  const _SidebarDivider();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.outlineVariant,
      child: const SizedBox(width: 1, height: double.infinity),
    );
  }
}

/// A thin draggable strip overlaid on the sidebar/pane seam. Dragging it
/// resizes the sidebar within [kSidebarMinWidth]–[kSidebarMaxWidth]. It's
/// transparent (the visible divider is [_SidebarDivider]) and translucent to
/// hit-testing, so only a horizontal drag is claimed here.
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
      ),
    );
  }
}
