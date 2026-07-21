import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'sidebar_layout.dart';

/// The top window-drag strip that stands in for the hidden OS titlebar
/// (SPEC-19 shared widget). Owns the [DragToMoveArea] fill plus the
/// traffic-light inset for an optional [leading] control (e.g. the sidebar
/// toggle). The single widget behind the strips previously hand-rolled in
/// `desktop_sidebar._Header`, `pane_tree_view`, and
/// `desktop_chat_pane._UnfoldStrip`.
///
/// The [leading] control is vertically **centred** in the strip, so it sits at
/// the same height regardless of the strip height or which call site hosts it
/// — the sidebar toggle must not jump when the sidebar is shown vs hidden.
class TitleBarStrip extends StatelessWidget {
  const TitleBarStrip({
    super.key,
    this.leading,
    this.title,
    this.trailing,
    this.titleInset = kTrafficLightInset,
  });

  /// Optional control pinned past the traffic lights (null → drag strip only).
  final Widget? leading;

  /// Optional interactive control pinned to the right edge of the strip (e.g.
  /// the "open in editor" button). Vertically centred; unlike [title] it stays
  /// tappable rather than being wrapped in an [IgnorePointer].
  final Widget? trailing;

  /// Optional label shown on the traffic-light row (e.g. the current worktree /
  /// branch), vertically centred and left-aligned at [titleInset].
  final Widget? title;

  /// Left inset of [title]. Defaults past the traffic lights; callers pass a
  /// smaller gutter when the strip does not overlap them (e.g. the pane area
  /// while the sidebar is shown).
  final double titleInset;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kTitleBarStripHeight,
      width: double.infinity,
      child: Stack(
        children: [
          const Positioned.fill(
            child: DragToMoveArea(child: SizedBox.expand()),
          ),
          if (title != null)
            Positioned(
              left: titleInset,
              top: 0,
              bottom: 0,
              // Reserve room for the trailing control so a long branch label
              // ellipsises before it instead of sliding under the button. The
              // OpenInIdeButton footprint is ~76px (Positioned right:4 + right
              // padding:8 + a ~36px logo segment + 2px gap + a ~26px caret
              // segment); 84 adds a small gap.
              right: trailing != null ? 84 : 8,
              // IgnorePointer so the label doesn't steal the window-drag zone
              // beneath it (it is a passive title, not an interactive control).
              child: IgnorePointer(
                child: Align(alignment: Alignment.centerLeft, child: title!),
              ),
            ),
          if (leading != null)
            Positioned(
              left: kTrafficLightInset,
              top: 0,
              bottom: 0,
              // Centre the control vertically so it stays put regardless of the
              // strip height or call site (sidebar shown vs hidden).
              child: Align(alignment: Alignment.centerLeft, child: leading!),
            ),
          if (trailing != null)
            Positioned(
              right: 4,
              top: 0,
              bottom: 0,
              child: Align(alignment: Alignment.centerRight, child: trailing!),
            ),
        ],
      ),
    );
  }
}

/// The sidebar fold/unfold button (SPEC-19 shared widget). [collapse] true hides
/// the sidebar ("Hide sidebar"); false restores it ("Show sidebar"). The single
/// widget behind the three hand-rolled `PhosphorIconsLight.sidebarSimple` buttons in
/// `desktop_sidebar`, `pane_tree_view`, and `desktop_chat_pane`.
class SidebarToggleButton extends ConsumerWidget {
  const SidebarToggleButton({super.key, required this.collapse});

  /// Whether pressing collapses (true) or expands (false) the sidebar.
  final bool collapse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      iconSize: 19,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      tooltip: collapse ? 'Hide sidebar' : 'Show sidebar',
      icon: const Icon(PhosphorIconsLight.sidebarSimple),
      onPressed: () =>
          ref.read(sidebarCollapsedProvider.notifier).state = collapse,
    );
  }
}
