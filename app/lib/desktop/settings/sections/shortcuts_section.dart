/// Shortcuts section body (SPEC-13 migration map).
///
/// Migrates the keyboard-shortcuts UI out of the retired `KeymapSettingsScreen`
/// into the two-pane Settings surface. Lists every [ShortcutAction] grouped by
/// scope (Chat = composer, Window = global) with its current [KeyChord] chip,
/// tap-to-rebind, per-row reset, and a "Reset all" affordance — all backed by
/// [keymapProvider]. The row/dialog logic mirrors the old screen; only the
/// scope headers adopt the [SettingsSectionHeader] idiom.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shortcuts/key_chord.dart';
import '../../../shortcuts/keymap.dart';
import '../../../shortcuts/keymap_controller.dart';
import '../../../shortcuts/shortcut_action.dart';
import 'section_header.dart';
import 'settings_group.dart';
import 'settings_reset_button.dart';

/// Shortcuts section body: every [ShortcutAction] grouped by scope, rebindable
/// and resettable, backed by [keymapProvider].
class ShortcutsSection extends ConsumerWidget {
  /// Creates the Shortcuts section body.
  const ShortcutsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keymap = ref.watch(keymapProvider);
    final defaults = Keymap.defaults(cmdIsPrimary: cmdIsPrimaryModifier);
    final anyModified = ShortcutAction.values.any(
      (a) => keymap.chordFor(a) != defaults.chordFor(a),
    );

    return ListView(
      children: [
        Row(
          children: [
            const Expanded(child: SettingsSectionHeader(title: 'Shortcuts')),
            if (anyModified)
              Padding(
                padding: const EdgeInsets.only(right: 16, top: 16),
                child: TextButton(
                  onPressed: () => ref.read(keymapProvider.notifier).resetAll(),
                  child: const Text('Reset all'),
                ),
              ),
          ],
        ),
        const SettingsSectionHeader(
          title: 'Chat',
          hint: 'Active while the message field is focused',
        ),
        SettingsGroup(
          children: [
            for (final action in _actionsInScope(ShortcutScope.composer))
              _ShortcutRow(action: action, keymap: keymap, defaults: defaults),
          ],
        ),
        const SettingsSectionHeader(
          title: 'Window',
          hint: 'Active anywhere in the window',
        ),
        SettingsGroup(
          children: [
            for (final action in _actionsInScope(ShortcutScope.global))
              _ShortcutRow(action: action, keymap: keymap, defaults: defaults),
          ],
        ),
      ],
    );
  }

  static List<ShortcutAction> _actionsInScope(ShortcutScope scope) =>
      ShortcutAction.values.where((a) => a.scope == scope).toList();
}

/// A single shortcut row: label + description, the current chord chip, a
/// per-row reset (↺, shown only when the chord differs from its default —
/// SPEC-13 #9), and tap-to-rebind.
class _ShortcutRow extends ConsumerWidget {
  const _ShortcutRow({
    required this.action,
    required this.keymap,
    required this.defaults,
  });

  final ShortcutAction action;
  final Keymap keymap;
  final Keymap defaults;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final chord = keymap.chordFor(action);
    final modified = chord != defaults.chordFor(action);

    return ListTile(
      title: Text(action.label),
      subtitle: Text(action.description),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (modified)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'Modified',
                style: TextStyle(color: cs.primary, fontSize: 12),
              ),
            ),
          _ChordChip(label: chord.label),
          const SizedBox(width: 8),
          SettingsResetButton(
            visible: modified,
            onPressed: () => ref.read(keymapProvider.notifier).reset(action),
          ),
        ],
      ),
      onTap: () => _rebind(context, ref),
    );
  }

  Future<void> _rebind(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final chord = await showDialog<KeyChord>(
      context: context,
      builder: (_) => _RecordChordDialog(action: action),
    );
    if (chord == null) return;
    // The dialog is async; bail if the section was disposed meanwhile so we
    // don't touch a stale messenger/ref.
    if (!context.mounted) return;

    // Global shortcuts must carry a non-shift modifier or they would swallow
    // ordinary typing; composer shortcuts (e.g. plain Enter) may be bare.
    if (action.scope == ShortcutScope.global && !chord.hasNonShiftModifier) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Window shortcuts need ⌘, ⌃, or ⌥.')),
      );
      return;
    }
    final conflict = keymap.conflictFor(chord, action.scope, ignore: action);
    if (conflict != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${chord.label} is already used by "${conflict.label}".',
          ),
        ),
      );
      return;
    }
    await ref.read(keymapProvider.notifier).rebind(action, chord);
  }
}

/// A monospace chip rendering a chord's [label] (e.g. `⌘,`).
class _ChordChip extends StatelessWidget {
  const _ChordChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFeatures: [FontFeature.tabularFigures()],
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Modal that captures the next non-modifier key press and returns it as a
/// [KeyChord]. Escape cancels.
class _RecordChordDialog extends StatefulWidget {
  const _RecordChordDialog({required this.action});
  final ShortcutAction action;

  @override
  State<_RecordChordDialog> createState() => _RecordChordDialogState();
}

class _RecordChordDialogState extends State<_RecordChordDialog> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_isModifier(key)) return KeyEventResult.handled;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final k = HardwareKeyboard.instance;
    Navigator.of(context).pop(
      KeyChord(
        key,
        meta: k.isMetaPressed,
        control: k.isControlPressed,
        alt: k.isAltPressed,
        shift: k.isShiftPressed,
      ),
    );
    return KeyEventResult.handled;
  }

  static bool _isModifier(LogicalKeyboardKey key) => {
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
  }.contains(key);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Set "${widget.action.label}"'),
      content: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Press the new shortcut…\n\nEsc to cancel.'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
