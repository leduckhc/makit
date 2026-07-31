import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/store.dart';
import 'desktop_group_reconcile.dart';
import 'groups/group.dart';
import 'groups/group_providers.dart';
import 'groups/groups_controller.dart';

/// Keeps the groups layer honest about what the server still has.
///
/// This provider owns one thing — **unpinning sessions the server no longer
/// lists** (SPEC-30 decision 6: a vanished session leaves every board's member
/// list, not merely its tabs; no dead tiles, no restore affordance) — and then
/// hands off, in a fixed order, to the reconcilers in
/// `desktop_group_reconcile.dart`:
///
/// 1. unpin vanished members (here), so membership is correct;
/// 2. [reconcileActiveCanvas], which reconciles the canvas *against* that
///    membership;
/// 3. [closeGroupsForDeletedWorktrees], on repo updates.
///
/// The order in (1) → (2) is why these are function calls rather than separate
/// providers: two listeners on the same `sessions.snapshot` would leave it
/// implicit, and reconciling before unpinning would place a session that is
/// about to be removed.
final desktopSessionPruneProvider = Provider<void>((ref) {
  void prune(SessionsState next) {
    // Before the first snapshot an empty list means "we don't know yet"
    // (offline, still connecting) — pruning then would wipe a restored layout.
    if (!ref.read(sessionsLoadedProvider)) return;
    final groupsCtrl = ref.read(groupsControllerProvider.notifier);

    // Decision 6: every board drops members the server no longer lists. Note
    // this also drops their tabs — `removeMember` keeps a board's membership and
    // its tree in agreement, so an inactive board cannot surface a dead tile
    // when it is next activated.
    for (final g in ref.read(groupsControllerProvider).groups) {
      if (g.kind != GroupKind.board) continue;
      for (final id in g.members) {
        if (next.byId(id) == null) groupsCtrl.removeMember(g.id, id);
      }
    }

    reconcileActiveCanvas(ref, next);
  }

  ref.listen(sessionsProvider, (_, next) => prune(next));
  // Membership also changes *without* a server snapshot: a quick-pin, a picker
  // tick or a drop all mutate it in-process (decision 14). Reconciling only off
  // `sessions.snapshot` meant a pinned agent had no pane until the next frame
  // the server happened to send — seconds later, or never on an idle desktop.
  //
  // Only the canvas half runs here: unpinning is the server's news, not the
  // user's, so there is nothing to prune on a local pin.
  ref.listen(activeGroupMembersKeyProvider, (_, _) {
    if (!ref.read(sessionsLoadedProvider)) return;
    reconcileActiveCanvas(ref, ref.read(sessionsProvider));
  });
  ref.listen(
    reposProvider,
    (_, next) => closeGroupsForDeletedWorktrees(ref, next),
  );
  Future.microtask(() {
    prune(ref.read(sessionsProvider));
    closeGroupsForDeletedWorktrees(ref, ref.read(reposProvider));
  });
});
