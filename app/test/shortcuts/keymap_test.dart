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
  });

  group('Keymap group-switch bindings (SPEC-30 decision 16)', () {
    final map = Keymap.defaults(cmdIsPrimary: true);

    test('⌘1…⌘9 are bound to the nine group-switch actions', () {
      const digits = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit7,
        LogicalKeyboardKey.digit8,
        LogicalKeyboardKey.digit9,
      ];
      for (var i = 0; i < 9; i++) {
        final action = ShortcutAction.switchGroupAtIndex(i)!;
        expect(
          map.chordFor(action),
          KeyChord(digits[i], meta: true),
          reason: 'group ${i + 1}',
        );
      }
    });

    test('there is no action for a tenth group', () {
      expect(ShortcutAction.switchGroupAtIndex(9), isNull);
    });

    test('groupIndex round-trips the switch actions', () {
      expect(ShortcutAction.switchGroup1.groupIndex, 0);
      expect(ShortcutAction.switchGroup9.groupIndex, 8);
      expect(ShortcutAction.newSession.groupIndex, isNull);
    });

    test('the digit chords do not conflict with any existing binding', () {
      for (var i = 0; i < 9; i++) {
        final action = ShortcutAction.switchGroupAtIndex(i)!;
        final chord = map.chordFor(action);
        expect(
          map.conflictFor(chord, ShortcutScope.global, ignore: action),
          isNull,
          reason: 'group ${i + 1} chord is free',
        );
      }
    });
  });
}
