import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
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
  const TitleBarStrip({super.key, this.leading, this.leadingTop = 7});

  /// Optional control pinned past the traffic lights (null → drag strip only).
  final Widget? leading;

  /// Top inset of [leading] within the strip.
  final double leadingTop;

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
/// widget behind the three hand-rolled `Symbols.thumbnail_bar` buttons in
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
      icon: const Icon(Symbols.dock_to_right, weight: 300),
      onPressed: () =>
          ref.read(sidebarCollapsedProvider.notifier).state = collapse,
    );
  }
}
