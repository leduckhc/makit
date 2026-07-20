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

/// A compact Material 3 *split button* for the title bar: two connected tonal
/// segments sharing one shape — a leading caret that toggles the editor menu
/// and a trailing segment whose logo opens the preferred editor. Follows the M3
/// split-button pattern (Flutter has no built-in widget on this channel):
/// `secondaryContainer` tonal fill, `InkWell` state layers, an outer
/// full-rounded / inner squared shape, and a caret that rotates while the menu
/// is open.
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

  static const double _height = 26;
  static const Radius _outer = Radius.circular(13);
  static const Radius _inner = Radius.circular(6);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // The caret segment brightens to the fuller `secondary` tone while its menu
    // is open (M3 selected/active state); the action segment stays tonal.
    final caretColor = menuOpen ? cs.secondary : cs.secondaryContainer;
    final caretFg = menuOpen ? cs.onSecondary : cs.onSecondaryContainer;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Leading: caret toggles the menu.
        _Segment(
          tooltip: 'Choose editor',
          onTap: onToggleMenu,
          color: caretColor,
          foreground: caretFg,
          radius: const BorderRadius.horizontal(left: _outer, right: _inner),
          height: _height,
          child: AnimatedRotation(
            turns: menuOpen ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: const Icon(PhosphorIconsLight.caretDown, size: 12),
          ),
        ),
        // 2px gap between segments gives the connected-shape M3 look.
        const SizedBox(width: 2),
        // Trailing: the preferred editor's logo opens it directly.
        _Segment(
          tooltip: actionTooltip,
          onTap: onAction,
          color: cs.secondaryContainer,
          foreground: cs.onSecondaryContainer,
          radius: const BorderRadius.horizontal(left: _inner, right: _outer),
          height: _height,
          child: ideLogo(context, preferred, size: 16),
        ),
      ],
    );
  }
}

/// One tonal segment of the [_IdeSplitButton]: a [Material] + [InkWell] so it
/// carries M3 state layers (hover/press ripple) and the given corner [radius].
/// The [foreground] drives the ambient [IconTheme] so a monochrome logo
/// ([IdeTarget.cursor]/[IdeTarget.iterm]) tints to match; colour logos ignore
/// it.
class _Segment extends StatelessWidget {
  const _Segment({
    required this.child,
    required this.onTap,
    required this.color,
    required this.foreground,
    required this.radius,
    required this.height,
    required this.tooltip,
  });

  final Widget child;
  final VoidCallback onTap;
  final Color color;
  final Color foreground;
  final BorderRadius radius;
  final double height;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: SizedBox(
            height: height,
            width: height,
            child: IconTheme.merge(
              data: IconThemeData(color: foreground, size: 16),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
