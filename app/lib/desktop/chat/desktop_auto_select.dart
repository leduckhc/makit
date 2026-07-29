import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import 'panes/split_node.dart';
import 'panes/workspace_controller.dart';

/// When the workspace shows no session at all (every tab is an empty
/// placeholder, or their sessions no longer resolve), reveal the most recently
/// active one so the workspace is useful on first launch (SPEC-10 Phase 1
/// acceptance). Reveal opens/focuses a tab in the active split via
/// [WorkspaceController].
///
/// Deliberately inert as soon as *any* tab anywhere hosts a live session: the
/// store re-emits [sessionsProvider] on every agent message and status change
/// (each bumps `lastActivityAt`), so a laxer rule dragged focus onto whichever
/// session was streaming — stealing it from an empty "New" tab the user was
/// working in, or binding that placeholder to the noisy session.
final desktopAutoSelectSessionProvider = Provider<void>((ref) {
  void pick(SessionsState next) {
    if (next.sessions.isEmpty) return;
    if (_showsAnySession(ref.read(workspaceControllerProvider), next)) return;
    final sorted = [...next.sessions]
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    ref
        .read(workspaceControllerProvider.notifier)
        .revealSession(sorted.first.id);
  }

  ref.listen(sessionsProvider, (_, next) => pick(next));
  Future.microtask(() => pick(ref.read(sessionsProvider)));
});

/// Whether any tab in any split hosts a session that still exists in [sessions]
/// — i.e. the workspace already shows something worth looking at.
bool _showsAnySession(WorkspaceState workspace, SessionsState sessions) =>
    firstSplitWhere(workspace.root, (split) {
      for (final tab in split.tabs) {
        final id = tab.sessionId;
        if (id != null && sessions.byId(id) != null) return true;
      }
      return null;
    }) ??
    false;
