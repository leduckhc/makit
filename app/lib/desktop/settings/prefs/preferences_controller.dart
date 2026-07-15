import 'dart:convert';

import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preference.dart';

/// SharedPreferences key holding all desktop settings overrides as a single
/// JSON object of `{ entryId: encodedValue }`. Only entries whose value differs
/// from their default are present — mirrors [kKeymapPrefsKey]'s diff-only
/// philosophy so "modified" and "reset" are derived, not tracked separately.
const String _kOverridesKey = 'desktop_settings_overrides';

/// Reads, persists, and mutates desktop [PreferenceEntry] values, storing only
/// diffs from each entry's code-defined default under a single key.
///
/// State is the immutable overrides map (`entryId -> encodedValue`); watchers
/// rebuild when it changes. Backed by a nullable [SharedPreferences]: when null
/// the controller is ephemeral (mutations update state but are not persisted),
/// used for the provider's default and in tests — mirroring [KeymapController].
class PreferencesController extends StateNotifier<Map<String, Object?>> {
  /// Creates a controller over [prefs], seeded from [initial] overrides.
  PreferencesController(this._prefs, Map<String, Object?> initial)
    : super(Map.unmodifiable(initial));

  /// A non-persisting controller with no overrides.
  PreferencesController.ephemeral() : this(null, const {});

  final SharedPreferences? _prefs;

  /// The SharedPreferences key under which the overrides map is stored.
  static String get storageKey => _kOverridesKey;

  /// Builds a controller from the persisted overrides. Corrupt JSON is ignored
  /// (treated as no overrides).
  static PreferencesController load(SharedPreferences prefs) =>
      PreferencesController(prefs, _decode(prefs.getString(_kOverridesKey)));

  static Map<String, Object?> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const {};
    }
    if (decoded is! Map) return const {};
    return {for (final e in decoded.entries) '${e.key}': e.value};
  }

  /// Returns the overridden value for [entry], or its default when unset or
  /// when the stored value cannot be decoded.
  T get<T>(PreferenceEntry<T> entry) {
    if (!state.containsKey(entry.id)) return entry.defaultValue;
    return entry.decode(state[entry.id]) ?? entry.defaultValue;
  }

  /// Whether [entry] currently has a stored override (differs from default).
  bool isModified<T>(PreferenceEntry<T> entry) => state.containsKey(entry.id);

  /// Sets [entry] to [value], writing through immediately. A value equal to the
  /// default removes the override; otherwise it is stored.
  Future<void> set<T>(PreferenceEntry<T> entry, T value) async {
    final next = Map<String, Object?>.from(state);
    if (value == entry.defaultValue) {
      next.remove(entry.id);
    } else {
      next[entry.id] = entry.encode(value);
    }
    state = Map.unmodifiable(next);
    await _persist();
  }

  /// Removes the override for [entry], reverting it to its default.
  Future<void> reset<T>(PreferenceEntry<T> entry) async {
    if (!state.containsKey(entry.id)) return;
    final next = Map<String, Object?>.from(state)..remove(entry.id);
    state = Map.unmodifiable(next);
    await _persist();
  }

  /// Clears every override, reverting all preferences to their defaults.
  Future<void> resetAll() async {
    state = const {};
    await _prefs?.remove(_kOverridesKey);
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (state.isEmpty) {
      await prefs.remove(_kOverridesKey);
    } else {
      await prefs.setString(_kOverridesKey, jsonEncode(state));
    }
  }
}
