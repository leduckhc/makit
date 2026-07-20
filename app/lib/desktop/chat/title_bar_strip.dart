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
/// [leadingTop] is the top inset of the [leading] control. It is a parameter
/// (rather than a fixed constant) so each call site keeps its existing
/// vertical offset — the cosmetic top:3-vs-top:7 normalisation is intentionally
/// deferred to avoid a behaviour change in this pure-move spec.
class TitleBarStrip extends StatelessWidget {
  const TitleBarStrip({
    super.key,
    this.leading,
    this.leadingTop = 7,
    this.title,
    this.titleInset = kTrafficLightInset,
  });

  /// Optional control pinned past the traffic lights (null → drag strip only).
  final Widget? leading;

  /// Top inset of [leading] within the strip.
  final double leadingTop;

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
              right: 8,
              // IgnorePointer so the label doesn't steal the window-drag zone
              // beneath it (it is a passive title, not an interactive control).
              child: IgnorePointer(
                child: Align(alignment: Alignment.centerLeft, child: title!),
              ),
            ),
          if (leading != null)
            Positioned(
              left: kTrafficLightInset,
              top: leadingTop,
              child: leading!,
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
