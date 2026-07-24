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
          const Expanded(child: WorkspaceView()),
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
          child: Stack(
            children: [
              // Title-band fill, right of the sidebar divider, so the top band
              // stays continuous with the sidebar + pane title
              // (surfaceContainer) with no gap.
              Positioned(
                left: 1,
                right: 0,
                top: 0,
                height: kTitleBarStripHeight,
                child: ColoredBox(color: cs.surfaceContainer),
              ),
              // Titlebar bottom hairline — right of the sidebar divider only,
              // so it meets but never crosses the sidebar; it continues into
              // the pane title strip's own divider.
              Positioned(
                left: 1,
                right: 0,
                top: kTitleBarStripHeight,
                height: 1,
                child: ColoredBox(color: cs.outlineVariant),
              ),
              // The sidebar divider: a full-height hairline flush against the
              // sidebar's edge, separating it from the title band and the chat
              // body below.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 1,
                child: ColoredBox(color: cs.outlineVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
