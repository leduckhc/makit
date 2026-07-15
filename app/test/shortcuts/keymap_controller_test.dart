import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/shortcuts/key_chord.dart';
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
}
