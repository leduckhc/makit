/// SPEC-30 — the seam every group-aware widget and reconciler reads.
///
/// Membership is **resolved here, never stored** for a worktree group: it is a
/// query over the live session list. Keeping that in one provider is what makes
/// "a worktree group shows exactly its branch, and nothing else" a property of
/// the system rather than a rule each call site has to remember.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/prefs/preference_entries.dart';
import '../../settings/prefs/preferences_providers.dart';
import '../../../store/models.dart';
import '../../../store/store.dart';
import '../panes/split_node.dart';
import 'group.dart';
import 'groups_controller.dart';

/// The group whose tree is on the canvas.
///
/// Watches the whole state deliberately: the *identity* of the active group is
/// not enough, since callers read its label, kind, scope and layout override.
/// `Group.==` includes the tree, so this DOES recompute on tree mutations —
/// which is why widgets that only need one field should select it from
/// [groupsControllerProvider] directly rather than watching this.
final activeGroupProvider = Provider<Group>(
  (ref) => ref.watch(groupsControllerProvider).active,
);

/// The live members of [groupId], in display order.
///
/// * worktree group → **derived**: every live session in its scope, ordered by
///   the session list (creation order), and nothing else.
/// * board → **curated**: its member list, filtered to sessions that still
///   exist (decision 6's counterpart — a vanished session is not a member).
final groupMembersProvider = Provider.family<List<String>, String>((
  ref,
  groupId,
) {
  // Select only what membership depends on — kind, scope and the curated list —
  // so a tree mutation (every focus/split/divider drag rewrites GroupsState via
  // commitTree) does not recompute membership for every group in the family.
  final group = ref.watch(
    groupsControllerProvider.select<_MembershipKey?>((s) {
      for (final g in s.groups) {
        if (g.id == groupId) {
          return _MembershipKey(
            kind: g.kind,
            projectId: g.projectId,
            worktreePath: g.worktreePath,
            members: g.members,
          );
        }
      }
      return null;
    }),
  );
  final sessions = ref.watch(sessionsProvider);
  if (group == null) return const [];

  switch (group.kind) {
    case GroupKind.worktree:
      return [
        for (final s in sessions.sessions)
          if (s.projectId == group.projectId &&
              s.worktreePath != null &&
              s.worktreePath == group.worktreePath)
            s.id,
      ];
    case GroupKind.board:
      return [
        for (final id in group.members)
          if (sessions.byId(id) != null) id,
      ];
  }
});

/// The slice of a [Group] that decides its membership. Equality over just these
/// fields is what lets [groupMembersProvider] ignore tree churn.
@immutable
class _MembershipKey {
  const _MembershipKey({
    required this.kind,
    required this.projectId,
    required this.worktreePath,
    required this.members,
  });

  final GroupKind kind;
  final String? projectId;
  final String? worktreePath;
  final List<String> members;

  @override
  bool operator ==(Object other) =>
      other is _MembershipKey &&
      other.kind == kind &&
      other.projectId == projectId &&
      other.worktreePath == worktreePath &&
      listEquals(other.members, members);

  @override
  int get hashCode =>
      Object.hash(kind, projectId, worktreePath, Object.hashAll(members));
}

/// The set of session ids the server still lists — what
/// [GroupsController.reopenBoard] and the prune need to filter against.
final liveSessionIdsProvider = Provider<Set<String>>(
  (ref) => {for (final s in ref.watch(sessionsProvider).sessions) s.id},
);

/// How [groupId] places a newly shown session: its own override when the user
/// arranged it, else the `layout.autoSplitThreshold` preference (decision 9).
///
/// This never re-arranges anything; it only answers "pane or tab?" for the next
/// session, which is why it is a plain derived value.
final layoutModeProvider = Provider.family<LayoutMode, String>((ref, groupId) {
  final groups = ref.watch(groupsControllerProvider);
  for (final g in groups.groups) {
    if (g.id == groupId) {
      final override = g.layoutOverride;
      if (override != null) return override;
      break;
    }
  }
  final shown = ref.watch(groupMembersProvider(groupId)).length;
  return shown >= ref.watch(autoSplitThresholdProvider)
      ? LayoutMode.tabs
      : LayoutMode.split;
});

/// The auto-split threshold as a plain value, so placement logic can stay pure.
final autoSplitThresholdProvider = Provider<int>((ref) {
  ref.watch(
    preferencesControllerProvider.select(
      (overrides) => overrides[autoSplitThresholdPreference.id],
    ),
  );
  return ref
      .read(preferencesControllerProvider.notifier)
      .get(autoSplitThresholdPreference);
});

/// Whether [group]'s stored tree already has a tab bound to [sessionId].
bool _treeHosts(Group group, String sessionId) =>
    firstSplitWhere<bool>(group.tree.root, (split) {
      for (final tab in split.tabs) {
        if (tab.sessionId == sessionId) return true;
      }
      return null;
    }) ??
    false;

/// Where [session] runs, for the membership rules. Null-safe on purpose: a
/// session with no worktree yet cannot be in any worktree group's scope.
SessionLocation locationOf(Session session) => SessionLocation(
  projectId: session.projectId,
  worktreePath: session.worktreePath,
);

/// The group that already contains [sessionId], resolved in SPEC-30 decision
/// 15's order: (a) the active group when it is already a member — no switch,
/// (b) its own worktree group when open, (c) any open board holding it,
/// (d) null, meaning the caller should mint its worktree group.
///
/// Navigation uses this instead of adding the session anywhere, which is why
/// clicking a session can never trigger decision 4's conversion.
String? groupHolding(
  GroupsState groups,
  Session session,
  List<String> Function(String groupId) membersOf,
) {
  final active = groups.active;
  if (membersOf(active.id).contains(session.id)) return active.id;
  // (a′) Already on screen somewhere. This catches the session the New-session
  // dialog just spawned: the server has not reported its worktree yet, so it is
  // in no group's *membership*, but its tab exists in the group it was started
  // from. Without this, clicking it would fall through to (d) and drag the user
  // into a different group than the one they are looking at.
  for (final g in groups.groups) {
    if (_treeHosts(g, session.id)) return g.id;
  }
  for (final g in groups.groups) {
    if (g.isScopedTo(
      projectId: session.projectId,
      worktreePath: session.worktreePath,
    )) {
      return g.id;
    }
  }
  for (final g in groups.groups) {
    if (g.kind == GroupKind.board && g.members.contains(session.id)) {
      return g.id;
    }
  }
  return null;
}
