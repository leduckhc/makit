import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'key_chord.dart';
import 'keymap.dart';
import 'shortcut_action.dart';

/// SharedPreferences key holding the user's chord overrides as a JSON object of
/// `{ actionId: chordJson }`. Only overrides are stored; unset actions fall
/// back to [Keymap.defaults] so future default changes reach existing users.
const String kKeymapPrefsKey = 'desktop_keymap_overrides';

/// Reads, persists, and mutates the desktop [Keymap]. Mirrors the
/// [ServerConfigController] pattern: seeded from prefs at the app root and
/// overridden into [keymapProvider].
class KeymapController extends StateNotifier<Keymap> {
  /// Creates a controller over [prefs], seeded from [initial]. When [prefs] is
  /// null the controller is ephemeral: mutations update state but are not
  /// persisted (used for the provider's non-desktop default and in tests).
  ///
  /// [base] is the platform-default keymap that `reset`/`resetAll` restore to
  /// and that persistence diffs against; it must stay distinct from any loaded
  /// overrides. Defaults to [initial] for callers (like the ephemeral and test
  /// constructors) that seed straight from defaults with no overrides applied.
  KeymapController(this._prefs, Keymap initial, {Keymap? base})
    : _base = base ?? initial,
      super(initial);

  /// A non-persisting controller seeded from the platform defaults.
  KeymapController.ephemeral({required bool cmdIsPrimary})
    : this(null, Keymap.defaults(cmdIsPrimary: cmdIsPrimary));

  final SharedPreferences? _prefs;

  /// The full default keymap for this platform; used to reset actions.
  final Keymap _base;

  /// The current keymap. Public accessor for non-widget composition code.
  Keymap get current => state;

  /// Builds a controller by merging persisted overrides over the platform
  /// defaults. Invalid or unknown overrides are ignored.
  static KeymapController load(
    SharedPreferences prefs, {
    required bool cmdIsPrimary,
  }) {
    final defaults = Keymap.defaults(cmdIsPrimary: cmdIsPrimary);
    final merged = _applyOverrides(defaults, prefs.getString(kKeymapPrefsKey));
    return KeymapController(prefs, merged, base: defaults);
  }

  static Keymap _applyOverrides(Keymap defaults, String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return defaults;
    }
    if (decoded is! Map) return defaults;
    var map = defaults;
    for (final entry in decoded.entries) {
      final action = ShortcutAction.byId('${entry.key}');
      final chord = KeyChord.fromJson(entry.value);
      if (action != null && chord != null) {
        map = map.rebind(action, chord);
      }
    }
    return map;
  }

  /// Rebinds [action] to [chord] and persists the override. No-ops when the
  /// chord is already bound to [action].
  Future<void> rebind(ShortcutAction action, KeyChord chord) async {
    if (state.chordFor(action) == chord) return;
    state = state.rebind(action, chord);
    await _persist();
  }

  /// Resets [action] to its platform default and persists.
  Future<void> reset(ShortcutAction action) async {
    await rebind(action, _base.chordFor(action));
  }

  /// Resets every action to its platform default and clears all overrides.
  Future<void> resetAll() async {
    state = _base;
    await _prefs?.remove(kKeymapPrefsKey);
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final overrides = <String, dynamic>{};
    for (final action in ShortcutAction.values) {
      final chord = state.chordFor(action);
      if (chord != _base.chordFor(action)) {
        overrides[action.id] = chord.toJson();
      }
    }
    if (overrides.isEmpty) {
      await prefs.remove(kKeymapPrefsKey);
    } else {
      await prefs.setString(kKeymapPrefsKey, jsonEncode(overrides));
    }
  }
}

/// The active desktop keymap. Defaults to a non-persisting controller seeded
/// from the platform defaults; `runDesktopApp` overrides it with a
/// [SharedPreferences]-backed one, and tests may override it too.
final keymapProvider = StateNotifierProvider<KeymapController, Keymap>(
  (ref) => KeymapController.ephemeral(cmdIsPrimary: cmdIsPrimaryModifier),
);

/// Whether the primary modifier should be Command (⌘). True on macOS.
bool get cmdIsPrimaryModifier => defaultTargetPlatform == TargetPlatform.macOS;
