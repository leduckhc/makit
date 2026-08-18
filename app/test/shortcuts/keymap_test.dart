import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/shortcuts/keymap.dart';
import 'package:makit/shortcuts/shortcut_action.dart';

void main() {
  test('rebind returns a new keymap and leaves the original alone', () {
    // Restored: this was `rebind`'s only dedicated coverage and went missing with
    // the ⌘1–9 work. Callers rely on it being pure — the settings screen keeps
    // the previous map to offer a reset.
    final base = Keymap.defaults(cmdIsPrimary: true);
    final original = base.chordFor(ShortcutAction.toggleSidebar);
    const chord = KeyChord(LogicalKeyboardKey.keyJ, meta: true);

    final next = base.rebind(ShortcutAction.toggleSidebar, chord);

    expect(next.chordFor(ShortcutAction.toggleSidebar), chord);
    expect(
      base.chordFor(ShortcutAction.toggleSidebar),
      original,
      reason: 'rebind must not mutate the receiver',
    );
    expect(next.bindings.length, base.bindings.length);
  });

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

    test('copy-newest-notice defaults to the primary modifier + shift + C', () {
      final cmd = Keymap.defaults(cmdIsPrimary: true);
      expect(
        cmd.chordFor(ShortcutAction.copyNewestNotice),
        const KeyChord(LogicalKeyboardKey.keyC, meta: true, shift: true),
      );
      final ctrl = Keymap.defaults(cmdIsPrimary: false);
      expect(
        ctrl.chordFor(ShortcutAction.copyNewestNotice),
        const KeyChord(LogicalKeyboardKey.keyC, control: true, shift: true),
      );
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

    test('openPorts defaults to ⌘⇧P on macOS (SPEC-ports-global-view D9)', () {
      final map = Keymap.defaults(cmdIsPrimary: true);
      expect(
        map.chordFor(ShortcutAction.openPorts),
        const KeyChord(LogicalKeyboardKey.keyP, meta: true, shift: true),
      );
    });

    test('openPorts defaults to ⌃⇧P off macOS (SPEC-ports-global-view D9)', () {
      final map = Keymap.defaults(cmdIsPrimary: false);
      expect(
        map.chordFor(ShortcutAction.openPorts),
        const KeyChord(LogicalKeyboardKey.keyP, control: true, shift: true),
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

    test(
      'openPorts ⌘⇧P is free in the global scope (SPEC-ports-global-view D9)',
      () {
        final chord = map.chordFor(ShortcutAction.openPorts);
        expect(
          map.conflictFor(
            chord,
            ShortcutScope.global,
            ignore: ShortcutAction.openPorts,
          ),
          isNull,
        );
      },
    );
  });

  group('Keymap group-switch bindings (SPEC-tab-groups decision 16)', () {
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

  // A map-wide invariant, not a group-switch one: its own group so a failure
  // names the whole default map rather than the ⌘1–9 work.
  group('Keymap default map invariants', () {
    final map = Keymap.defaults(cmdIsPrimary: true);

    test('no two actions share a chord in the same scope', () {
      for (final action in ShortcutAction.values) {
        expect(
          map.conflictFor(map.chordFor(action), action.scope, ignore: action),
          isNull,
          reason: '${action.id} collides with another default binding',
        );
      }
    });
  });
}
