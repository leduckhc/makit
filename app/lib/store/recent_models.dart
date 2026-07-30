import 'dart:convert';

import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key holding the recent-model lists as a single JSON object
/// of `{ agentId: [modelValue, …] }`, most-recent-first. Mirrors
/// [PreferencesController]'s single-JSON-key, corrupt-tolerant philosophy
/// (SPEC-31, option C — the recent list is the *only* persisted state).
const String _kRecentModelsKey = 'recent_models';

/// The most models remembered per agent. Older selections fall off the tail.
const int kRecentModelsMax = 7;

/// Remembers the model values a user has recently selected, per agent, so the
/// model picker can surface a short Recent list instead of the full ~300-entry
/// catalog (SPEC-31). Selections are recorded **optimistically on the user's
/// gesture** — `configOption` actions are fire-and-forget with no success
/// signal, so there is no ack to wait for.
///
/// State is the immutable `agentId -> [modelValue, …]` map (most-recent-first);
/// watchers rebuild when it changes. Backed by a nullable [SharedPreferences]:
/// when null the controller is ephemeral (mutations update state but are not
/// persisted), used for the provider's default and in tests — mirroring
/// [PreferencesController].
class RecentModelsController extends StateNotifier<Map<String, List<String>>> {
  /// Creates a controller over [prefs], seeded from [initial] recents.
  RecentModelsController(this._prefs, Map<String, List<String>> initial)
    : super(Map.unmodifiable(initial));

  /// A non-persisting controller with no recents.
  RecentModelsController.ephemeral() : this(null, const {});

  final SharedPreferences? _prefs;

  /// The SharedPreferences key under which the recents map is stored.
  static String get storageKey => _kRecentModelsKey;

  /// Builds a controller from the persisted recents. Corrupt JSON, or an entry
  /// whose value is not a list of strings, is ignored (treated as absent).
  static RecentModelsController load(SharedPreferences prefs) =>
      RecentModelsController(
        prefs,
        _decode(prefs.getString(_kRecentModelsKey)),
      );

  static Map<String, List<String>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const {};
    }
    if (decoded is! Map) return const {};
    final result = <String, List<String>>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is! List) continue;
      final models = value.whereType<String>().toList();
      if (models.isNotEmpty) result['${entry.key}'] = models;
    }
    return result;
  }

  /// The recent model values for [agent], most-recent-first (empty when none).
  List<String> recentModels(String agent) => state[agent] ?? const [];

  /// Records that the user selected [value] for [agent]: prepend it, drop any
  /// earlier occurrence (so it moves to the front), and cap the list at
  /// [kRecentModelsMax]. Writes through immediately.
  Future<void> recordSelect(String agent, String value) async {
    final current = state[agent] ?? const [];
    final next = <String>[value, ...current.where((v) => v != value)];
    final capped = next.length > kRecentModelsMax
        ? next.sublist(0, kRecentModelsMax)
        : next;
    state = Map.unmodifiable({...state, agent: capped});
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (state.isEmpty) {
      await prefs.remove(_kRecentModelsKey);
    } else {
      await prefs.setString(_kRecentModelsKey, jsonEncode(state));
    }
  }
}

/// The active recent-models store. Defaults to a non-persisting controller; the
/// desktop (`runDesktopApp`) and mobile (`main`) bootstraps override it with a
/// [SharedPreferences]-backed one, and tests may override it too.
final recentModelsControllerProvider =
    StateNotifierProvider<RecentModelsController, Map<String, List<String>>>(
      (ref) => RecentModelsController.ephemeral(),
    );
