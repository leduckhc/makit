import 'package:flutter_riverpod/legacy.dart';

import '../../store/models.dart';

/// The transcript rows the user has unfolded, keyed by
/// [transcriptRowExpansionKey].
///
/// Held app-wide (deliberately **not** `autoDispose`) because unfolding is the
/// user's own decision and must outlive the widget that shows it. Kept in the
/// row's `State` (as it used to be) it was lost every time the element went
/// away: the lazy list evicting the row from its cache, switching session,
/// splitting or rebinding a desktop pane, closing and reopening a tab. It also
/// gave each split pane its own private answer for the same call.
///
/// Holding it here is also what let [ToolCallCard] and [ThinkingLine] drop
/// `AutomaticKeepAliveClientMixin`: the row has no state left worth pinning into
/// the sliver's keep-alive slot.
class ExpandedTranscriptRows extends StateNotifier<Set<String>> {
  ExpandedTranscriptRows() : super(const {});

  bool isExpanded(String key) => state.contains(key);

  /// Unfolds [key] if folded, folds it if unfolded.
  void toggle(String key) => state = state.contains(key)
      ? (Set<String>.of(state)..remove(key))
      : {...state, key};
}

final expandedTranscriptRowsProvider =
    StateNotifierProvider<ExpandedTranscriptRows, Set<String>>(
      (ref) => ExpandedTranscriptRows(),
    );

/// Stable identity for a foldable transcript row, scoped by session.
///
/// Tool calls key on `callId` (stable across the streamed `running → ok` updates
/// that replace the item); everything else keys on `seq`. Both are only unique
/// *within* a session — `callId` comes from the agent, which numbers its calls
/// per session — so the session id has to be part of the key, or unfolding a
/// tool in one session would unfold an unrelated row in another.
String transcriptRowExpansionKey(String sessionId, ChatItem item) =>
    switch (item) {
      ToolCallItem() => '$sessionId/tool/${item.callId}',
      _ => '$sessionId/seq/${item.seq}',
    };
