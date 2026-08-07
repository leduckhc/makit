/// The starter pane's pending-session picks (SPEC-45 D2) — the harness it will
/// run and the config values that ride the spawn.
///
/// Held app-wide and keyed by the starter's draft key (deliberately **not**
/// `autoDispose`, exactly like `composerDraftsProvider` and
/// `composerAttachmentsProvider`) because the pane does not outlive a tab
/// switch: `split_view.dart` keys `DesktopChatPane` by tab id, so state owned by
/// the widget is destroyed the moment another tab is shown.
///
/// A separate store from the draft *text* because it is a different shape, not a
/// different lifetime: the two are keyed identically and pruned at the same
/// moment (a started session spends both).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';

/// One pane's pending session: the harness, and the config-option values picked
/// for it. `agentId` null means "no explicit choice yet" — the starter then
/// falls back to the first available harness, as it always has.
@immutable
class StarterPicks {
  const StarterPicks({this.agentId, this.picks = const {}});

  final String? agentId;

  /// Pending config-option values keyed by option id, forwarded to the spawn.
  final Map<String, Object> picks;

  bool get isEmpty => agentId == null && picks.isEmpty;
}

/// In-memory store of pending-session picks, keyed by starter draft key.
class StarterPicksStore extends StateNotifier<Map<String, StarterPicks>> {
  StarterPicksStore() : super(const {});

  StarterPicks? forKey(String key) => state[key];

  /// Records the harness choice for [key], dropping any config picks made for
  /// the previous one: a different harness has its own catalog and defaults, so
  /// a stale pick could name a value it cannot honour.
  ///
  /// Re-affirming the harness already chosen is a no-op. The cards stay tappable
  /// while selected, and replacing the entry unconditionally threw away the model
  /// picked *for that harness* — only a change of harness may drop them.
  void chooseAgent(String key, String agentId) {
    if (state[key]?.agentId == agentId) return;
    state = {...state, key: StarterPicks(agentId: agentId)};
  }

  /// Records one config-option pick for [key], keeping the harness choice.
  void setPick(String key, String optionId, Object value) {
    final current = state[key] ?? const StarterPicks();
    state = {
      ...state,
      key: StarterPicks(
        agentId: current.agentId,
        picks: {...current.picks, optionId: value},
      ),
    };
  }

  /// Forgets [key] — the pending session became a real one (or its worktree is
  /// gone), so the map only ever holds live drafts.
  void clear(String key) {
    if (!state.containsKey(key)) return;
    state = Map<String, StarterPicks>.of(state)..remove(key);
  }
}

final starterPicksProvider =
    StateNotifierProvider<StarterPicksStore, Map<String, StarterPicks>>(
      (ref) => StarterPicksStore(),
    );
