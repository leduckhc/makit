import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../settings/prefs/preference_entries.dart';
import '../settings/prefs/preferences_providers.dart';

/// The external apps the title-bar "Open in…" split button can launch for the
/// current worktree path (macOS desktop only).
enum IdeTarget {
  vscode('VS Code', 'Visual Studio Code'),
  cursor('Cursor', 'Cursor'),
  zed('Zed', 'Zed'),
  ghostty('Ghostty', 'Ghostty'),
  iterm('iTerm2', 'iTerm'),
  terminal('Terminal', 'Terminal'),
  finder('Finder', 'Finder');

  const IdeTarget(this.label, this.appName);

  /// Human-readable menu label (e.g. "iTerm2").
  final String label;

  /// The macOS application name passed to `open -a` (e.g. "iTerm", whose bundle
  /// differs from its marketing name).
  final String appName;
}

/// The `open` invocation that reveals [path] in [target]. Split out as a pure
/// function so the command mapping is unit-testable without spawning processes.
///
/// Finder opens the folder directly (`open <path>`); the editors/terminals
/// launch by application name (`open -a "<App>" <path>`) so no CLI shim (`code`,
/// `cursor`, …) needs to be installed.
({String executable, List<String> args}) ideOpenCommand(
  IdeTarget target,
  String path,
) {
  return switch (target) {
    IdeTarget.finder => (executable: 'open', args: [path]),
    _ => (executable: 'open', args: ['-a', target.appName, path]),
  };
}

/// Resolves the stored [preferredIdePreference] name to an [IdeTarget],
/// falling back to VS Code for an unknown/legacy value.
IdeTarget ideTargetFromName(String name) => IdeTarget.values.firstWhere(
  (t) => t.name == name,
  orElse: () => IdeTarget.vscode,
);

/// Renders the official brand logo for [target] at [size], adapting to the
/// current [Theme] brightness.
///
/// Three flavours, matching what an official logo is actually available for:
///  * Full-colour brand SVGs (VS Code, Zed, Ghostty) from selfhst/icons — the
///    `-light` variant is used on dark backgrounds.
///  * Monochrome brand marks (Cursor, iTerm2) from Simple Icons — tinted to the
///    ambient icon colour so they read in both themes.
///  * A neutral Phosphor glyph for Apple's Terminal and Finder, which have no
///    official distributable SVG (so we don't fabricate one).
Widget ideLogo(BuildContext context, IdeTarget target, {double size = 18}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final tint = IconTheme.of(context).color;

  String colored(String base) => 'assets/ide/$base${dark ? '-light' : ''}.svg';
  Widget svg(String asset, {Color? tintColor}) => SvgPicture.asset(
    asset,
    width: size,
    height: size,
    colorFilter: tintColor == null
        ? null
        : ColorFilter.mode(tintColor, BlendMode.srcIn),
  );

  return switch (target) {
    IdeTarget.vscode => svg(colored('visual-studio-code')),
    IdeTarget.zed => svg(colored('zed')),
    IdeTarget.ghostty => svg(colored('ghostty')),
    IdeTarget.cursor => svg('assets/ide/cursor.svg', tintColor: tint),
    IdeTarget.iterm => svg('assets/ide/iterm2.svg', tintColor: tint),
    IdeTarget.terminal => Icon(PhosphorIconsLight.terminal, size: size),
    IdeTarget.finder => Icon(PhosphorIconsLight.folderOpen, size: size),
  };
}

/// Title-bar split button that opens the current worktree [path] in a popular
/// IDE or Finder. The main button opens the last-picked editor
/// ([preferredIdePreference]); the caret opens a menu to choose another, which
/// becomes the new preferred. Shown on the right of the window title strip;
/// macOS only.
class OpenInIdeButton extends ConsumerWidget {
  const OpenInIdeButton({super.key, required this.path});

  /// The worktree directory to open.
  final String path;

  static String _actionLabel(IdeTarget target) => target == IdeTarget.finder
      ? 'Reveal in Finder'
      : 'Open in ${target.label}';

  Future<void> _open(BuildContext context, IdeTarget target) async {
    final cmd = ideOpenCommand(target, path);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final result = await Process.run(cmd.executable, cmd.args);
      if (result.exitCode != 0) {
        messenger?.showSnackBar(
          SnackBar(content: Text('Could not open ${target.label}')),
        );
      }
    } on ProcessException {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not open ${target.label}')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferred = ideTargetFromName(ref.preference(preferredIdePreference));
    // Trailing 8px keeps the control off the window's right edge.
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: MenuAnchor(
        alignmentOffset: const Offset(0, 4),
        menuChildren: [
          for (final target in IdeTarget.values)
            MenuItemButton(
              leadingIcon: ideLogo(context, target, size: 20),
              trailingIcon: target == preferred
                  ? const Icon(PhosphorIconsLight.check, size: 16)
                  : null,
              onPressed: () {
                ref
                    .read(preferencesControllerProvider.notifier)
                    .set(preferredIdePreference, target.name);
                _open(context, target);
              },
              child: Text(_actionLabel(target)),
            ),
        ],
        builder: (context, controller, _) => _IdeSplitButton(
          preferred: preferred,
          actionTooltip: _actionLabel(preferred),
          menuOpen: controller.isOpen,
          onAction: () => _open(context, preferred),
          onToggleMenu: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
      ),
    );
  }
}

/// A Material 3 *split button* (Expressive, XS size) for the title bar. The
/// caret segment (menu toggle, whose icon rotates 180° while the menu is open)
/// sits on the left; the preferred editor's logo sits on the right and opens it
/// directly. Both segments share one shape: outer corners fully rounded (50%),
/// inner corners squared (4dp) with a 2dp gap between them. It fills with `surfaceContainer` so it blends
/// into the chat background it sits on, lifting a tone (to
/// `surfaceContainerHighest`) while the caret's menu is open.
class _IdeSplitButton extends StatelessWidget {
  const _IdeSplitButton({
    required this.preferred,
    required this.actionTooltip,
    required this.menuOpen,
    required this.onAction,
    required this.onToggleMenu,
  });

  final IdeTarget preferred;
  final String actionTooltip;
  final bool menuOpen;
  final VoidCallback onAction;
  final VoidCallback onToggleMenu;

  // XS split-button metrics (M3 tokens, scaled to fit the 32dp title strip).
  static const double _height = 28;
  static const double _outer = _height / 2; // 50% → fully rounded outer corner.
  static const double _inner = 4; // XS inner corner size.

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Rest on the chat-content surface so the control blends into the title
    // strip; the caret lifts a tone while its menu is open (neutral active).
    final surface = cs.surfaceContainer;
    final fg = cs.onSurface;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Leading: the menu toggle. Lifts a tone while open; the caret rotates.
        _Segment(
          tooltip: 'Choose editor',
          onTap: onToggleMenu,
          background: menuOpen ? cs.surfaceContainerHighest : surface,
          foreground: fg,
          height: _height,
          outerRadius: _outer,
          innerRadius: _inner,
          leadingEdge: true,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: AnimatedRotation(
            turns: menuOpen ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: const Icon(PhosphorIconsLight.caretDown, size: 14),
          ),
        ),
        // 2dp gap between segments (fixed across all sizes per the spec).
        const SizedBox(width: 2),
        // Trailing: the primary action — open the preferred editor directly.
        _Segment(
          tooltip: actionTooltip,
          onTap: onAction,
          background: surface,
          foreground: fg,
          height: _height,
          outerRadius: _outer,
          innerRadius: _inner,
          leadingEdge: false,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: ideLogo(context, preferred, size: 16),
        ),
      ],
    );
  }
}

/// One tonal segment of the [_IdeSplitButton]: a [Material] + [InkWell] carrying
/// M3 state layers (hover/press ripple) with an asymmetric shape — [outerRadius]
/// on its outer edge and [innerRadius] on the edge that faces the gap. The
/// [foreground] drives the ambient [IconTheme] so a monochrome logo
/// ([IdeTarget.cursor]/[IdeTarget.iterm]) tints to match; colour logos ignore
/// it.
class _Segment extends StatelessWidget {
  const _Segment({
    required this.child,
    required this.onTap,
    required this.background,
    required this.foreground,
    required this.height,
    required this.outerRadius,
    required this.innerRadius,
    required this.leadingEdge,
    required this.padding,
    required this.tooltip,
  });

  final Widget child;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;
  final double height;
  final double outerRadius;
  final double innerRadius;

  /// True for the leading segment (outer corner on the left, inner on the
  /// right); false mirrors it for the trailing segment.
  final bool leadingEdge;
  final EdgeInsets padding;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final outer = Radius.circular(outerRadius);
    final inner = Radius.circular(innerRadius);
    final radius = leadingEdge
        ? BorderRadius.horizontal(left: outer, right: inner)
        : BorderRadius.horizontal(left: inner, right: outer);

    return Tooltip(
      message: tooltip,
      child: SizedBox(
        height: height,
        child: Material(
          color: background,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: padding,
              child: IconTheme.merge(
                data: IconThemeData(color: foreground, size: 16),
                child: Center(widthFactor: 1, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
