import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/shortcuts/key_chord.dart';
import 'package:makit/shortcuts/keymap.dart';
import 'package:makit/shortcuts/keymap_controller.dart';
import 'package:makit/shortcuts/shortcut_action.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<KeymapController> newController() async {
    final prefs = await SharedPreferences.getInstance();
    return KeymapController.load(prefs, cmdIsPrimary: true);
  }

  test('load returns defaults when nothing is persisted', () async {
    final c = await newController();
    expect(
      c.current.chordFor(ShortcutAction.openSettings),
      const KeyChord(LogicalKeyboardKey.comma, meta: true),
    );
  });

  test('rebind persists and survives reload', () async {
    final prefs = await SharedPreferences.getInstance();
    final c = KeymapController.load(prefs, cmdIsPrimary: true);
    const chord = KeyChord(LogicalKeyboardKey.keyK, meta: true);
    await c.rebind(ShortcutAction.newSession, chord);

    final reloaded = KeymapController.load(prefs, cmdIsPrimary: true);
    expect(reloaded.current.chordFor(ShortcutAction.newSession), chord);
  });

  test('reset restores a single action default', () async {
    final c = await newController();
    final original = c.current.chordFor(ShortcutAction.newSession);
    await c.rebind(
      ShortcutAction.newSession,
      const KeyChord(LogicalKeyboardKey.keyK, meta: true),
    );
    await c.reset(ShortcutAction.newSession);
    expect(c.current.chordFor(ShortcutAction.newSession), original);
  });

  test('resetAll clears every override', () async {
    final prefs = await SharedPreferences.getInstance();
    final c = KeymapController.load(prefs, cmdIsPrimary: true);
    await c.rebind(
      ShortcutAction.newSession,
      const KeyChord(LogicalKeyboardKey.keyK, meta: true),
    );
    await c.resetAll();
    expect(prefs.getString(kKeymapPrefsKey), isNull);
    expect(c.current, KeymapController.load(prefs, cmdIsPrimary: true).current);
  });

  test('only overrides are persisted, not the whole map', () async {
    final prefs = await SharedPreferences.getInstance();
    final c = KeymapController.load(prefs, cmdIsPrimary: true);
    await c.rebind(
      ShortcutAction.newSession,
      const KeyChord(LogicalKeyboardKey.keyK, meta: true),
    );
    final raw = prefs.getString(kKeymapPrefsKey)!;
    expect(raw, contains('newSession'));
    expect(raw, isNot(contains('openSettings')));
  });

  test('unknown or malformed overrides are ignored on load', () async {
    SharedPreferences.setMockInitialValues({
      kKeymapPrefsKey: '{"bogusAction":{"key":1},"newSession":"garbage"}',
    });
    final prefs = await SharedPreferences.getInstance();
    final c = KeymapController.load(prefs, cmdIsPrimary: true);
    // Falls back to the default for newSession (garbage chord ignored).
    expect(
      c.current.chordFor(ShortcutAction.newSession),
      const KeyChord(LogicalKeyboardKey.keyN, meta: true),
    );
  });

  test(
    'reset after reload restores the platform default, not the override',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const override = KeyChord(LogicalKeyboardKey.keyK, meta: true);
      await KeymapController.load(
        prefs,
        cmdIsPrimary: true,
      ).rebind(ShortcutAction.newSession, override);

      // Fresh controller seeded from the persisted override.
      final reloaded = KeymapController.load(prefs, cmdIsPrimary: true);
      expect(reloaded.current.chordFor(ShortcutAction.newSession), override);

      await reloaded.reset(ShortcutAction.newSession);
      expect(
        reloaded.current.chordFor(ShortcutAction.newSession),
        const KeyChord(LogicalKeyboardKey.keyN, meta: true),
      );
      expect(prefs.getString(kKeymapPrefsKey), isNull);
    },
  );

  test('resetAll after reload restores defaults and clears prefs', () async {
    final prefs = await SharedPreferences.getInstance();
    await KeymapController.load(prefs, cmdIsPrimary: true).rebind(
      ShortcutAction.newSession,
      const KeyChord(LogicalKeyboardKey.keyK, meta: true),
    );

    final reloaded = KeymapController.load(prefs, cmdIsPrimary: true);
    await reloaded.resetAll();
    expect(reloaded.current, Keymap.defaults(cmdIsPrimary: true));
    expect(prefs.getString(kKeymapPrefsKey), isNull);
  });

  test(
    'rebinding a second action after reload preserves the first override',
    () async {
      final prefs = await SharedPreferences.getInstance();
      const first = KeyChord(LogicalKeyboardKey.keyK, meta: true);
      await KeymapController.load(
        prefs,
        cmdIsPrimary: true,
      ).rebind(ShortcutAction.newSession, first);

      // Reload from the persisted override, then rebind a different action.
      final reloaded = KeymapController.load(prefs, cmdIsPrimary: true);
      const second = KeyChord(LogicalKeyboardKey.keyJ, meta: true);
      await reloaded.rebind(ShortcutAction.toggleSidebar, second);

      final raw = prefs.getString(kKeymapPrefsKey)!;
      expect(
        raw,
        contains('newSession'),
        reason: 'first override must survive',
      );
      expect(raw, contains('toggleSidebar'));

      final second2 = KeymapController.load(prefs, cmdIsPrimary: true);
      expect(second2.current.chordFor(ShortcutAction.newSession), first);
      expect(second2.current.chordFor(ShortcutAction.toggleSidebar), second);
    },
  );
}
