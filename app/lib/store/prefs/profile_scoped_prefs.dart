/// A profile-scoped view over [SharedPreferences].
///
/// Exists because `SharedPreferences.setPrefix` — the mechanism makit uses today
/// to namespace a worktree build's settings — **throws** once `getInstance()` has
/// run:
///
/// ```
/// StateError('setPrefix cannot be called after getInstance')
/// ```
///
/// That single line makes switching profiles inside a running window impossible,
/// and `resetStatic()` is `@visibleForTesting` (it also drops a cache other
/// controllers still hold references through), so it is not an option. Moving the
/// profile segment out of the plugin's global prefix and into keys we compose
/// ourselves removes the global mutable state entirely (SPEC-50 D11).
///
/// **The migration is a no-op.** `shared_preferences` composes stored keys by
/// plain concatenation, `'$_prefix$key'`, so with the plugin left at its default
/// `flutter.` prefix, `'<id>.desktop_server_port'` lands on exactly the byte
/// sequence `setPrefix('flutter.<id>.')` + `'desktop_server_port'` produced. The
/// legacy profile carries an empty segment, so its keys are untouched. Both
/// equivalences are asserted in `profile_registry_test.dart`.
///
/// Only **server-bound** preferences are scoped: server config, groups and pane
/// layouts. Appearance, shortcuts, recent models and cached commands are
/// user-level and deliberately stay shared — the old blanket prefix is why a
/// worktree build opened with a default theme and empty shortcuts.
library;

import 'package:shared_preferences/shared_preferences.dart';

/// The narrow read/write surface the scoped controllers need.
///
/// Deliberately an interface rather than a subclass: `SharedPreferences` has a
/// private constructor and static state, so it cannot be subclassed cleanly, and
/// depending on the small surface instead of the whole plugin is what lets a
/// controller be tested without any plugin at all.
abstract interface class ScopedPrefs {
  /// Reads a string, or `null`.
  String? getString(String key);

  /// Writes a string.
  Future<bool> setString(String key, String value);

  /// Reads an int, or `null`.
  int? getInt(String key);

  /// Writes an int.
  Future<bool> setInt(String key, int value);

  /// Reads a bool, or `null`.
  bool? getBool(String key);

  /// Writes a bool.
  Future<bool> setBool(String key, bool value);

  /// Reads a string list, or `null`.
  List<String>? getStringList(String key);

  /// Writes a string list.
  Future<bool> setStringList(String key, List<String> value);

  /// Removes a key.
  Future<bool> remove(String key);

  /// Whether a key is present.
  bool containsKey(String key);

  /// Every key visible through this scope, with the scope prefix stripped.
  Set<String> keys();
}

/// A [ScopedPrefs] that prefixes every key with a profile's segment.
class ProfileScopedPrefs implements ScopedPrefs {
  /// Wraps [prefs], prefixing every key with [prefix].
  ///
  /// [prefix] is `ServerProfile.prefsKeyPrefix`: `''` for the legacy profile and
  /// `'<id>.'` for every other. An empty prefix is the identity scope, which is
  /// exactly what the legacy profile needs.
  const ProfileScopedPrefs(this._prefs, this.prefix);

  /// A scope over the whole store, used where a preference is user-level rather
  /// than profile-bound (appearance, shortcuts, recent models).
  const ProfileScopedPrefs.unscoped(SharedPreferences prefs) : this(prefs, '');

  final SharedPreferences _prefs;

  /// The key segment this scope prepends. `''` means "no scoping".
  final String prefix;

  String _k(String key) => '$prefix$key';

  @override
  String? getString(String key) => _prefs.getString(_k(key));

  @override
  Future<bool> setString(String key, String value) =>
      _prefs.setString(_k(key), value);

  @override
  int? getInt(String key) => _prefs.getInt(_k(key));

  @override
  Future<bool> setInt(String key, int value) => _prefs.setInt(_k(key), value);

  @override
  bool? getBool(String key) => _prefs.getBool(_k(key));

  @override
  Future<bool> setBool(String key, bool value) =>
      _prefs.setBool(_k(key), value);

  @override
  List<String>? getStringList(String key) => _prefs.getStringList(_k(key));

  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _prefs.setStringList(_k(key), value);

  @override
  Future<bool> remove(String key) => _prefs.remove(_k(key));

  @override
  bool containsKey(String key) => _prefs.containsKey(_k(key));

  /// Keys belonging to this scope only, with [prefix] stripped.
  ///
  /// Filtering matters: with the plugin left unscoped, `_prefs.getKeys()` returns
  /// **every** profile's keys, so an unfiltered caller would see and could delete
  /// another profile's settings.
  @override
  Set<String> keys() {
    final all = _prefs.getKeys();
    if (prefix.isEmpty) {
      // The legacy scope owns the unprefixed keys. Anything containing a '.'
      // segment before a known key belongs to a namespaced profile, but we
      // cannot distinguish "id.key" from a legitimately dotted key, so the
      // legacy scope reports everything and callers must ask for known keys.
      return all;
    }
    return {
      for (final k in all)
        if (k.startsWith(prefix)) k.substring(prefix.length),
    };
  }

  /// Removes every key in this scope. Refuses to run on an unscoped view, where
  /// it could not tell this profile's keys from another's.
  ///
  /// Returns the number of keys removed, or `-1` when refused.
  Future<int> clearScope() async {
    if (prefix.isEmpty) return -1;
    final mine = _prefs.getKeys().where((k) => k.startsWith(prefix)).toList();
    for (final k in mine) {
      await _prefs.remove(k);
    }
    return mine.length;
  }
}
