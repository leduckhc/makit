import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/shortcuts/keymap.dart';
import 'package:makit/shortcuts/shortcut_action.dart';

void main() {
  group('KeyChord', () {
    test('round-trips through JSON', () {
      const chord = KeyChord(LogicalKeyboardKey.enter, meta: true, shift: true);
      final restored = KeyChord.fromJson(chord.toJson());
      expect(restored, chord);
    });

    test('fromJson rejects malformed payloads', () {
      expect(KeyChord.fromJson(null), isNull);
      expect(KeyChord.fromJson({'meta': true}), isNull);
      expect(KeyChord.fromJson('nope'), isNull);
    });

    test('toActivator carries modifiers', () {
      const chord = KeyChord(LogicalKeyboardKey.comma, meta: true);
      final act = chord.toActivator();
      expect(act.trigger, LogicalKeyboardKey.comma);
      expect(act.meta, isTrue);
      expect(act.control, isFalse);
    });

    test('label uses canonical modifier symbols', () {
      expect(const KeyChord(LogicalKeyboardKey.enter, shift: true).label, '⇧↵');
      expect(const KeyChord(LogicalKeyboardKey.comma, meta: true).label, '⌘,');
      expect(
        const KeyChord(LogicalKeyboardKey.keyN, control: true).label,
        '⌃N',
      );
    });

    test('hasNonShiftModifier distinguishes bare/shift keys', () {
      expect(
        const KeyChord(LogicalKeyboardKey.enter).hasNonShiftModifier,
        isFalse,
      );
      expect(
        const KeyChord(
          LogicalKeyboardKey.enter,
          shift: true,
        ).hasNonShiftModifier,
        isFalse,
      );
      expect(
        const KeyChord(
          LogicalKeyboardKey.enter,
          meta: true,
        ).hasNonShiftModifier,
        isTrue,
      );
    });
  });

  group('Keymap.defaults', () {
    test('uses ⌘ as primary on macOS', () {
      final map = Keymap.defaults(cmdIsPrimary: true);
      expect(map.chordFor(ShortcutAction.openSettings).meta, isTrue);
      expect(map.chordFor(ShortcutAction.openSettings).control, isFalse);
    });

    test('uses Ctrl as primary elsewhere', () {
      final map = Keymap.defaults(cmdIsPrimary: false);
      expect(map.chordFor(ShortcutAction.openSettings).control, isTrue);
      expect(map.chordFor(ShortcutAction.openSettings).meta, isFalse);
    });

    test('binds every action', () {
      final map = Keymap.defaults(cmdIsPrimary: true);
      for (final action in ShortcutAction.values) {
        expect(map.bindings[action], isNotNull, reason: action.id);
      }
    });

    test('send default is plain Enter', () {
      final map = Keymap.defaults(cmdIsPrimary: true);
      expect(
        map.chordFor(ShortcutAction.sendMessage),
        const KeyChord(LogicalKeyboardKey.enter),
      );
    });

    test('newline default is Shift+Enter', () {
      final map = Keymap.defaults(cmdIsPrimary: true);
      expect(
        map.chordFor(ShortcutAction.composerNewline),
        const KeyChord(LogicalKeyboardKey.enter, shift: true),
      );
    });
  });

  group('Keymap conflicts', () {
    final map = Keymap.defaults(cmdIsPrimary: true);

    test('detects a clash within the same scope', () {
      final clash = map.chordFor(ShortcutAction.newSession);
      expect(
        map.conflictFor(clash, ShortcutScope.global),
        ShortcutAction.newSession,
      );
    });

    test('ignores the action being rebound', () {
      final own = map.chordFor(ShortcutAction.newSession);
      expect(
        map.conflictFor(
          own,
          ShortcutScope.global,
          ignore: ShortcutAction.newSession,
        ),
        isNull,
      );
    });

    test('allows the same chord across different scopes', () {
      // sendMessage (composer) and openSettings (global) could share a chord.
      final send = map.chordFor(ShortcutAction.sendMessage);
      expect(map.conflictFor(send, ShortcutScope.global), isNull);
    });

    test('rebind returns a new map without mutating the original', () {
      const chord = KeyChord(LogicalKeyboardKey.keyK, meta: true);
      final next = map.rebind(ShortcutAction.newSession, chord);
      expect(next.chordFor(ShortcutAction.newSession), chord);
      expect(map.chordFor(ShortcutAction.newSession), isNot(chord));
    });
  });
}
