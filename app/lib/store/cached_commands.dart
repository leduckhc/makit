/// Cached slash-command palettes (SPEC-starter-pane-parity D3–D5).
///
/// The "Choose a harness" starter pane has no session, and agent commands only
/// ever arrive on a live session's `session.commands` (ACP delivers them as an
/// `available_commands_update` notification *after* `session/new`, never in its
/// response). So the palette a pane can offer before its session exists is the
/// one a live session in the same project already advertised — remembered here.
///
/// Keyed `agentId + projectId`: a command list is cwd-dependent (project skills
/// and prompts are not global), so it cannot be keyed by harness alone, while
/// sibling worktrees of one repo share their project files and would only
/// multiply cache misses if keyed per worktree.
///
/// Persistence mirrors [RecentModelsController] exactly — one JSON blob under a
/// single SharedPreferences key, corrupt-tolerant, with a non-persisting default
/// controller for tests.
library;

import 'dart:convert';

import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// SharedPreferences key holding every cached palette as one JSON object of
/// `{ "<agent>\u0000<projectId>": [ {name, description, source, location}, … ] }`.
const String _kCachedCommandsKey = 'cached_commands';

/// How many `(agent, project)` palettes are remembered before the
/// oldest-written one is evicted. pi advertises ~100 commands per project, so
/// this is what keeps a long-lived install's prefs blob bounded.
const int kCachedCommandKeysMax = 12;

/// Cache key for one harness in one project. `\u0000` cannot occur in either id,
/// so the two can never be confused by a separator appearing inside a value.
String _key(String agent, String projectId) => '$agent\u0000$projectId';

/// Remembers the slash commands a live session advertised, per harness and
/// project, so a sessionless pane can offer the same palette.
///
/// Only observations are stored: nothing is synthesised, and an empty
/// advertisement is ignored rather than written (it carries nothing the palette
/// can use, and overwriting a known list with it is a pure regression).
class CachedCommandsController
    extends StateNotifier<Map<String, List<SlashCmd>>> {
  /// Creates a controller over [prefs], seeded with [initial] palettes.
  CachedCommandsController(this._prefs, Map<String, List<SlashCmd>> initial)
    : super(Map.unmodifiable(initial));

  /// A non-persisting controller with an empty cache.
  CachedCommandsController.ephemeral() : this(null, const {});

  final SharedPreferences? _prefs;

  /// The SharedPreferences key under which the cache is stored.
  static String get storageKey => _kCachedCommandsKey;

  /// Builds a controller from the persisted cache. Corrupt JSON, a value that
  /// is not a list, and an entry that is not a usable command are all ignored
  /// (treated as absent) rather than throwing — this runs in the desktop
  /// bootstrap, where an exception is a failure to start, not a lost palette.
  static CachedCommandsController load(SharedPreferences prefs) =>
      CachedCommandsController(
        prefs,
        _decode(prefs.getString(_kCachedCommandsKey)),
      );

  static Map<String, List<SlashCmd>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const {};
    }
    if (decoded is! Map) return const {};
    final result = <String, List<SlashCmd>>{};
    for (final entry in decoded.entries) {
      final value = entry.value;
      if (value is! List) continue;
      final cmds = <SlashCmd>[];
      for (final entryValue in value) {
        if (entryValue is! Map) continue;
        try {
          final cmd = SlashCmd.fromJson(Map<String, dynamic>.from(entryValue));
          if (cmd != null) cmds.add(cmd);
        } on Object {
          // `SlashCmd.fromJson` casts (`as String?`), so a wrong-TYPED field
          // throws instead of returning null — `whereType` cannot filter that,
          // and one bad entry would otherwise take the whole cache (and the
          // bootstrap that loads it) down with it.
          continue;
        }
      }
      if (cmds.isNotEmpty) result['${entry.key}'] = cmds;
    }
    return result;
  }

  /// The remembered palette for [agent] in [projectId] (empty when unseen).
  List<SlashCmd> commandsFor(String agent, String projectId) =>
      state[_key(agent, projectId)] ?? const [];

  /// Records what a live session advertised. Replaces that pair's palette
  /// wholesale (an update is the whole picture), moves it to the newest end of
  /// the eviction order, and drops the oldest entries past
  /// [kCachedCommandKeysMax]. An empty [commands] is a no-op.
  Future<void> record({
    required String agent,
    required String projectId,
    required List<SlashCmd> commands,
  }) async {
    if (commands.isEmpty) return;
    final key = _key(agent, projectId);
    // Re-inserting after a remove is what refreshes the key's place in the
    // insertion-ordered map, so a pair still in use is not evicted for being
    // first written.
    final next = Map<String, List<SlashCmd>>.of(state)..remove(key);
    next[key] = List.unmodifiable(commands);
    while (next.length > kCachedCommandKeysMax) {
      next.remove(next.keys.first);
    }
    state = Map.unmodifiable(next);
    await _persist();
  }

  /// Forget every cached palette (and the persisted blob).
  ///
  /// Called when the active server changes: project ids are host-local, so the
  /// old desktop's palettes are not merely stale but wrong under the new one —
  /// the same reason `StoreController` empties its state there.
  Future<void> clearAll() async {
    if (state.isEmpty) return;
    state = const {};
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final wire = {
      for (final entry in state.entries)
        entry.key: [
          for (final c in entry.value)
            {
              'name': c.name,
              'description': c.description,
              'source': c.source,
              if (c.location != null) 'location': c.location,
            },
        ],
    };
    if (wire.isEmpty) {
      await prefs.remove(_kCachedCommandsKey);
    } else {
      await prefs.setString(_kCachedCommandsKey, jsonEncode(wire));
    }
  }
}

/// The active command cache. Defaults to a non-persisting controller; the
/// desktop (`runDesktopApp`) and mobile (`main`) bootstraps override it with a
/// [SharedPreferences]-backed one, and tests may override it too.
final cachedCommandsControllerProvider =
    StateNotifierProvider<
      CachedCommandsController,
      Map<String, List<SlashCmd>>
    >((ref) => CachedCommandsController.ephemeral());
