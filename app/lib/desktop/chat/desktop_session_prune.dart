import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import 'panes/split_node.dart';
import 'panes/workspace_controller.dart';

/// Keeps the workspace honest about what the server still has: every tab bound
/// to a session that is absent from the latest `sessions.snapshot` is closed.
///
/// A session can vanish while its tab is open — archived or quit from another
/// client (the phone, a second desktop) — and a persisted layout can be
/// restored pointing at sessions the server no longer lists at all. Both used
/// to leave a tab that renders the empty-pane starter, indistinguishable from a
/// "New" tab the user opened on purpose. Closing them collapses/resets splits
/// through [WorkspaceController.unbindSession], and once nothing is bound the
/// auto-select (see `desktop_auto_select.dart`) reveals a live session again.
final desktopSessionPruneProvider = Provider<void>((ref) {
  void prune(SessionsState next) {
    // Before the first snapshot an empty list means "we don't know yet"
    // (offline, still connecting) — pruning then would wipe a restored layout.
    if (!ref.read(sessionsLoadedProvider)) return;
    final workspace = ref.read(workspaceControllerProvider.notifier);
    for (final id in _boundSessionIds(ref.read(workspaceControllerProvider))) {
      if (next.byId(id) == null) workspace.unbindSession(id);
    }
  }

  ref.listen(sessionsProvider, (_, next) => prune(next));
  Future.microtask(() => prune(ref.read(sessionsProvider)));
});

/// Every session id hosted by a tab anywhere in [workspace].
List<String> _boundSessionIds(WorkspaceState workspace) {
  final ids = <String>[];
  // `select` never returns a match, so the walk visits every split.
  firstSplitWhere<bool>(workspace.root, (split) {
    ids.addAll(split.tabs.map((t) => t.sessionId).nonNulls);
    return null;
  });
  return ids;
}
