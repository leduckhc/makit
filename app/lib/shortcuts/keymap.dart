import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'key_chord.dart';
import 'shortcut_action.dart';

/// An immutable binding of every [ShortcutAction] to a [KeyChord].
///
/// Built from platform-appropriate [Keymap.defaults] and then layered with the
/// user's persisted overrides. Rebinding returns a new [Keymap]; nothing
/// mutates in place.
@immutable
class Keymap {
  /// Creates a keymap from a complete action→chord map.
  const Keymap(this.bindings);

  /// The full binding table. Guaranteed to contain every [ShortcutAction].
  final Map<ShortcutAction, KeyChord> bindings;

  /// The chord bound to [action].
  KeyChord chordFor(ShortcutAction action) => bindings[action]!;

  /// The default keymap. When [cmdIsPrimary] (macOS) the primary modifier is
  /// Command (⌘); elsewhere it is Control (⌃).
  factory Keymap.defaults({required bool cmdIsPrimary}) {
    KeyChord primary(LogicalKeyboardKey key, {bool shift = false}) =>
        KeyChord(key, meta: cmdIsPrimary, control: !cmdIsPrimary, shift: shift);
    return Keymap({
      ShortcutAction.sendMessage: const KeyChord(LogicalKeyboardKey.enter),
      ShortcutAction.composerNewline: const KeyChord(
        LogicalKeyboardKey.enter,
        shift: true,
      ),
      ShortcutAction.focusComposer: primary(LogicalKeyboardKey.keyL),
      ShortcutAction.newSession: primary(LogicalKeyboardKey.keyN),
      ShortcutAction.toggleSidebar: primary(LogicalKeyboardKey.keyB),
      ShortcutAction.nextSession: primary(LogicalKeyboardKey.bracketRight),
      ShortcutAction.previousSession: primary(LogicalKeyboardKey.bracketLeft),
      ShortcutAction.openSettings: primary(LogicalKeyboardKey.comma),
      ShortcutAction.splitVertical: primary(LogicalKeyboardKey.keyD),
      ShortcutAction.splitHorizontal: primary(
        LogicalKeyboardKey.keyD,
        shift: true,
      ),
      ShortcutAction.newTab: primary(LogicalKeyboardKey.keyT),
      ShortcutAction.closeSplit: primary(LogicalKeyboardKey.keyW),
      ShortcutAction.closeTab: primary(LogicalKeyboardKey.keyW, shift: true),
      ShortcutAction.nextTab: primary(
        LogicalKeyboardKey.bracketRight,
        shift: true,
      ),
      ShortcutAction.prevTab: primary(
        LogicalKeyboardKey.bracketLeft,
        shift: true,
      ),
    });
  }

  /// Returns a copy with [action] rebound to [chord].
  Keymap rebind(ShortcutAction action, KeyChord chord) =>
      Keymap({...bindings, action: chord});

  /// Any action (other than [ignore]) already bound to [chord] within the same
  /// [ShortcutScope]. Two actions in different scopes may safely share a chord.
  /// Returns null when [chord] is free.
  ShortcutAction? conflictFor(
    KeyChord chord,
    ShortcutScope scope, {
    ShortcutAction? ignore,
  }) {
    for (final entry in bindings.entries) {
      if (entry.key == ignore) continue;
      if (entry.key.scope != scope) continue;
      if (entry.value == chord) return entry.key;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is Keymap && mapEquals(other.bindings, bindings);

  @override
  int get hashCode => Object.hashAllUnordered(
    bindings.entries.map((e) => Object.hash(e.key, e.value)),
  );
}
