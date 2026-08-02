import 'dart:convert';

import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preference.dart';
import 'preference_entries.dart';

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

  /// Ids of internal (non-user-facing) entries, excluded from the modified
  /// count and preserved across [resetAll].
  static final Set<String> _internalIds = {
    for (final e in kPreferenceEntries)
      if (e.internal) e.id,
  };

  /// The SharedPreferences key under which the overrides map is stored.
  static String get storageKey => _kOverridesKey;

  /// Builds a controller from the persisted overrides. Corrupt JSON is ignored
  /// (treated as no overrides), and surviving entries are normalised — see
  /// [_normalize].
  static PreferencesController load(SharedPreferences prefs) =>
      PreferencesController(
        prefs,
        _normalize(_decode(prefs.getString(_kOverridesKey))),
      );

  /// Drops stored entries that no longer represent a real override, so [get],
  /// [isModified] and [modifiedUserFacingCount] cannot disagree.
  ///
  /// [set] already prunes a default-valued write, so divergence only arrives
  /// from disk: a value written by another app version that no longer decodes
  /// (a renamed enum, say), or one that now *equals* the default because the
  /// shipped default changed under it. Either way [get] hands back the default
  /// while the entry's presence claimed "modified", which showed a phantom in
  /// the "N settings changed" count and armed Reset-all over nothing.
  ///
  /// Ids we do not recognise are left alone: they belong to a newer build, and
  /// running an older one must not wipe them.
  static Map<String, Object?> _normalize(Map<String, Object?> stored) {
    if (stored.isEmpty) return stored;
    final known = {for (final e in kPreferenceEntries) e.id: e};
    final out = <String, Object?>{};
    for (final entry in stored.entries) {
      final known0 = known[entry.key];
      if (known0 == null) {
        out[entry.key] = entry.value; // unknown id — preserve verbatim
        continue;
      }
      final decoded = known0.decode(entry.value);
      if (decoded == null) continue; // no longer decodable
      if (decoded == known0.defaultValue) continue; // now the default
      out[entry.key] = entry.value;
    }
    return out;
  }

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

  /// The number of user-facing preferences that differ from their default.
  ///
  /// Internal bookkeeping entries (e.g. the remembered last section) are
  /// excluded so they don't inflate the "N settings changed" count or enable
  /// Reset-all when no real preference has changed. So are ids we don't know:
  /// they are kept on disk for a newer build (see [_normalize]) but they are not
  /// settings *this* build can claim the user changed.
  int get modifiedUserFacingCount {
    var count = 0;
    final knownIds = {for (final e in kPreferenceEntries) e.id};
    for (final id in state.keys) {
      if (!_internalIds.contains(id) && knownIds.contains(id)) count++;
    }
    return count;
  }

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

  /// Clears every user-facing override, reverting those preferences to their
  /// defaults. Internal bookkeeping entries (e.g. the remembered last section)
  /// are preserved — and so are ids this build does not recognise.
  ///
  /// The unknown-id case mirrors [_normalize]: an id from a newer build is
  /// preserved on load precisely because it is not ours to delete, so Reset-all
  /// must not be the thing that deletes it. It is also not a setting this build
  /// could offer to reset — it does not appear in any section.
  Future<void> resetAll() async {
    final knownIds = {for (final e in kPreferenceEntries) e.id};
    final next = <String, Object?>{
      for (final e in state.entries)
        if (_internalIds.contains(e.key) || !knownIds.contains(e.key))
          e.key: e.value,
    };
    state = Map.unmodifiable(next);
    await _persist();
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
