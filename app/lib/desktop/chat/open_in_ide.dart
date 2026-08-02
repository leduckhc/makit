import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/prefs/preference_entries.dart';
import '../../store/prefs/preferences_providers.dart';

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

  /// The worktree directory to open, or **null** when there is nothing to open
  /// (SPEC-30 decision 11: a board with no focused pane owns no scope). A null
  /// path renders the launcher disabled rather than pointing it at nothing —
  /// the control never lies about a target.
  final String? path;

  /// Whether there is a folder to open. The appearance is otherwise unchanged;
  /// only the enabled/disabled state and the target vary (decision 11).
  bool get _enabled => path != null;

  static String _actionLabel(IdeTarget target) => target.label;

  Future<void> _open(BuildContext context, IdeTarget target) async {
    final path = this.path;
    if (path == null) return;
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
          // SPEC-30 decision 11: the button is icon-only *because* the menu
          // names the exact folder — "so the control cannot lie". Decision 10
          // also removed the title strip's branch label, so without this header
          // nothing on screen says which worktree will open. Non-interactive.
          if (_enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Opens the active pane',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    // Head-truncate the path: the worktree name (the tail) is
                    // the identifying part, so a deep path drops its *leading*
                    // segments to a '…' rather than clipping the name.
                    _PathHeadEllipsis(
                      path: path!,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          for (final target in IdeTarget.values)
            MenuItemButton(
              leadingIcon: ideLogo(context, target, size: 13),
              trailingIcon: target == preferred
                  ? const Icon(PhosphorIconsLight.check, size: 16)
                  : null,
              onPressed: () {
                ref
                    .read(preferencesControllerProvider.notifier)
                    .set(preferredIdePreference, target.name);
                _open(context, target);
              },
              child: Text(
                _actionLabel(target),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
        ],
        builder: (context, controller, _) => _IdeSplitButton(
          preferred: preferred,
          // A disabled launcher must not narrate an action it will not take.
          actionTooltip: _enabled
              ? _actionLabel(preferred)
              : 'Nothing to open — this board has no panes',
          enabled: _enabled,
          menuOpen: controller.isOpen,
          onAction: _enabled ? () => _open(context, preferred) : null,
          onToggleMenu: _enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
        ),
      ),
    );
  }
}

/// A compact split button for the title bar, styled to match [PrStatusPill] /
/// the PR-actions split button: a single `surfaceContainer` fill (the window-
/// title background it sits on) with a uniform [kRadius8] radius and a 1px
/// `outlineVariant` hairline border. A leading logo segment opens the preferred
/// editor; a trailing caret segment (menu toggle, whose icon rotates 180° while
/// open) is separated by a 1px divider — no gap. The caret lifts a tone
/// (`surfaceContainerHighest`) while its menu is open.
class _IdeSplitButton extends StatelessWidget {
  const _IdeSplitButton({
    required this.preferred,
    required this.actionTooltip,
    required this.enabled,
    required this.menuOpen,
    required this.onAction,
    required this.onToggleMenu,
  });

  final IdeTarget preferred;
  final String actionTooltip;
  final bool enabled;
  final bool menuOpen;
  final VoidCallback? onAction;
  final VoidCallback? onToggleMenu;

  static const double _height = 24;
  static const double _logoSize = 15;
  static const Radius _radius = Radius.circular(kRadius8);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Rest on the window-title background so the control blends into the strip;
    // the caret lifts a tone while its menu is open (neutral active).
    final surface = cs.surfaceContainer;
    final fg = cs.onSurface;
    final button = Material(
      color: surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(_radius),
        side: BorderSide(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Leading: the primary action — open the preferred editor directly.
          Tooltip(
            message: actionTooltip,
            child: InkWell(
              onTap: onAction,
              child: SizedBox(
                height: _height,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: kSpace8),
                  // The ambient IconTheme tints monochrome logos
                  // (cursor/iterm) to match; colour logos ignore it.
                  child: IconTheme.merge(
                    data: IconThemeData(color: fg, size: _logoSize),
                    child: Center(
                      widthFactor: 1,
                      child: ideLogo(context, preferred, size: _logoSize),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 1px divider between the segments (no gap), matching the border.
          Container(width: 1, height: _height, color: cs.outlineVariant),
          // Trailing: the menu toggle. Lifts a tone while open; caret rotates.
          // Ink (not a nested Material) paints the open-state tone as an ink
          // feature on the outer Material, keeping a single Material layer
          // while the InkWell's splashes still render above the colour.
          Tooltip(
            message: enabled ? 'Choose editor' : '',
            child: Ink(
              color: menuOpen ? cs.surfaceContainerHighest : surface,
              child: InkWell(
                onTap: onToggleMenu,
                child: SizedBox(
                  height: _height,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: kSpace4),
                    child: AnimatedRotation(
                      turns: menuOpen ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        PhosphorIconsLight.caretDown,
                        size: kPillIconSize,
                        color: fg,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    // Enabled renders exactly as before (goldens are frozen by decision 11); a
    // disabled launcher dims to read as inert, matching the mock's dead state.
    return _disabledDim(button);
  }

  /// Uniform `Opacity` rather than M3's token-based disabled colours, matching
  /// how this app dims every other unavailable affordance — an unavailable
  /// harness card (`new_session_sheet.dart`), an inactive tab chip and a
  /// dragging chip (`split_view.dart`), an unchosen ask tile (`ask_card.dart`).
  /// Review preferred the M3 idiom; adopting it here alone would make this the
  /// only control in the app that dims differently.
  Widget _disabledDim(Widget button) => enabled
      ? button
      // IgnorePointer as well as dimming: without it the disabled control still
      // takes hover cursors and is discoverable by assistive technology, i.e. it
      // advertises an action it will not perform.
      : IgnorePointer(child: Opacity(opacity: 0.4, child: button));
}

/// A single-line [path] that truncates from the **head**: the trailing segment
/// (the worktree/folder name) is the identifying part, so when the path is too
/// wide the leading segments collapse to a `…` prefix instead of the tail being
/// clipped by a normal end-ellipsis.
///
/// Truncation is measured against a fixed [maxWidth] with a [TextPainter] in
/// build (not a LayoutBuilder): this widget lives inside a [MenuAnchor], which
/// asks its children for intrinsic dimensions, and LayoutBuilder cannot answer
/// that. A precomputed plain [Text] can.
class _PathHeadEllipsis extends StatelessWidget {
  const _PathHeadEllipsis({required this.path, required this.style});

  final String path;
  final TextStyle? style;

  /// The 260 header cap, less its 12+12 padding.
  static const double _maxWidth = 236;

  @override
  Widget build(BuildContext context) {
    return Text(
      _fit(path, style, _maxWidth, MediaQuery.textScalerOf(context)),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }

  /// The longest tail of [path] that fits [maxWidth], prefixed with `…` once any
  /// head was dropped. Returns the full path when it already fits. Measures with
  /// the same [scaler] the rendered [Text] uses, so a text-scale > 1 can't make
  /// the precomputed tail wider than the widget and clip the worktree name.
  static String _fit(
    String path,
    TextStyle? style,
    double maxWidth,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: scaler,
    );
    double widthOf(String s) {
      painter.text = TextSpan(text: s, style: style);
      painter.layout();
      return painter.width;
    }

    try {
      if (widthOf(path) <= maxWidth) return path;
      // Drop leading characters until the '…'-prefixed tail fits.
      for (var start = 1; start < path.length; start++) {
        if (widthOf('…${path.substring(start)}') <= maxWidth) {
          return '…${path.substring(start)}';
        }
      }
      return '…';
    } finally {
      painter.dispose();
    }
  }
}
