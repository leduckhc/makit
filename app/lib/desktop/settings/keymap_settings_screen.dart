import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shortcuts/key_chord.dart';
import '../../shortcuts/keymap.dart';
import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';

/// Settings page listing every [ShortcutAction] and its current [KeyChord],
/// with tap-to-rebind and per-row / global reset. Backed by [keymapProvider].
class KeymapSettingsScreen extends ConsumerWidget {
  /// Creates the keyboard-shortcuts settings page.
  const KeymapSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keymap = ref.watch(keymapProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Keyboard shortcuts'),
        actions: [
          TextButton(
            onPressed: () => ref.read(keymapProvider.notifier).resetAll(),
            child: const Text('Reset all'),
          ),
        ],
      ),
      body: ListView(
        children: [
          const _ScopeHeader(
            label: 'Chat',
            hint: 'Active while the message field is focused',
          ),
          for (final action in _actionsInScope(ShortcutScope.composer))
            _ShortcutRow(action: action, keymap: keymap),
          const Divider(),
          const _ScopeHeader(
            label: 'Window',
            hint: 'Active anywhere in the window',
          ),
          for (final action in _actionsInScope(ShortcutScope.global))
            _ShortcutRow(action: action, keymap: keymap),
        ],
      ),
    );
  }

  static List<ShortcutAction> _actionsInScope(ShortcutScope scope) =>
      ShortcutAction.values.where((a) => a.scope == scope).toList();
}

class _ScopeHeader extends StatelessWidget {
  const _ScopeHeader({required this.label, required this.hint});
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: cs.primary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          Text(hint, style: TextStyle(color: cs.outline, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ShortcutRow extends ConsumerWidget {
  const _ShortcutRow({required this.action, required this.keymap});
  final ShortcutAction action;
  final Keymap keymap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chord = keymap.chordFor(action);
    return ListTile(
      title: Text(action.label),
      subtitle: Text(action.description),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChordChip(label: chord.label),
          IconButton(
            tooltip: 'Reset to default',
            icon: const Icon(Icons.settings_backup_restore, size: 18),
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
    // The dialog is async; bail if the settings screen was disposed meanwhile
    // so we don't touch a stale messenger/ref.
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
            '${chord.label} is already used by '
            '"${conflict.label}".',
          ),
        ),
      );
      return;
    }
    await ref.read(keymapProvider.notifier).rebind(action, chord);
  }
}

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
