import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import 'groups/group_providers.dart';
import 'panes/split_node.dart';
import 'panes/workspace_controller.dart';

/// When the active group's canvas shows no session at all (every tab is an
/// empty placeholder, or their sessions no longer resolve), reveal the most
/// recently active session **that is already a member of the active group** so
/// the canvas is useful on first launch (SPEC-10 Phase 1 acceptance).
///
/// SPEC-30 makes this group-aware: it may only reveal a session within the
/// active group's membership. Revealing a foreign session would inject it into
/// the active group's tree, bypassing `addMember` and breaking decisions 4, 5
/// and 15. If nothing in the group qualifies it stays **inert** — it must never
/// switch groups on its own (decision 5).
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
    // Only sessions the active group already contains are candidates; a
    // foreign session is never revealed and the group is never switched.
    final active = ref.read(activeGroupProvider);
    final members = ref.read(groupMembersProvider(active.id)).toSet();
    final candidates = [
      for (final s in next.sessions)
        if (members.contains(s.id)) s,
    ];
    if (candidates.isEmpty) return;
    candidates.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    ref
        .read(workspaceControllerProvider.notifier)
        .revealSession(candidates.first.id);
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
