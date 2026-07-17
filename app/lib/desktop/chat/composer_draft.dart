import 'package:flutter_riverpod/legacy.dart';

/// In-memory store of composer draft text, keyed by a stable draft id (the
/// session id for an active session, or a worktree-scoped key for a session
/// that hasn't started yet).
///
/// Held app-wide (deliberately **not** `autoDispose`) so a half-typed message
/// survives the composer's widget being disposed and recreated — the two ways
/// a draft used to vanish on desktop: switching the selected worktree, and
/// splitting/reflowing the pane tree. Cleared drafts (post-send) are pruned so
/// the map only ever holds live drafts.
class ComposerDrafts extends StateNotifier<Map<String, String>> {
  ComposerDrafts() : super(const {});

  String? textFor(String key) => state[key];

  /// Store [text] for [key], or prune the entry when [text] is empty.
  void set(String key, String text) {
    if (text.isEmpty) {
      if (!state.containsKey(key)) return;
      state = Map<String, String>.of(state)..remove(key);
      return;
    }
    if (state[key] == text) return;
    state = {...state, key: text};
  }
}

final composerDraftsProvider =
    StateNotifierProvider<ComposerDrafts, Map<String, String>>(
      (ref) => ComposerDrafts(),
    );
