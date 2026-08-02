/// Regression: reconciling the canvas from the membership-key listener must not
/// write groups state *inside* Riverpod's refresh pass.
///
/// `reconcileActiveCanvas` commits the tree back into `GroupsState`, which
/// re-dirties `activeGroupProvider` (it watches the whole state, and
/// `Group.==` includes the tree). Riverpod's `_performRefresh` re-reads
/// `stateToRefresh.length` on every iteration, so a provider dirtied by a
/// listener that fired *during* the pass is flushed again in the SAME pass —
/// tripping `debugNotifyDidBuild` with "Tried to rebuild `Provider<Group>`
/// multiple times in the same frame".
///
/// That throw escapes `_performRefresh`, which sets `_builtWithinFrame` without
/// try/finally, so the debug guard stays armed for the rest of the process and
/// every provider poisons on its second rebuild.
///
/// The missing ingredient in the other prune tests is a live listener on
/// `activeGroupProvider`: without one it is never in `stateToRefresh`, so it
/// never builds twice. The app always has one (`split_view`'s `+` tooltip,
/// `AgentPicker`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_session_prune.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/group_providers.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session(String id) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: id,
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
);

Group _boardWithTabs(String id, List<String> ids) {
  final c = WorkspaceController(null, WorkspaceController.seedWorkspace());
  for (final sid in ids) {
    c.revealSession(sid);
  }
  return Group.board(id: id, label: id, members: ids, tree: c.state);
}

final _snapshot = StateProvider<({List<Session> sessions, bool loaded})>(
  (ref) => (sessions: const [], loaded: false),
);

void main() {
  test('pinning to the active board does not rebuild activeGroupProvider '
      'twice in one refresh pass', () async {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          (ref) => SessionsState(ref.watch(_snapshot).sessions),
        ),
        sessionsLoadedProvider.overrideWith(
          (ref) => ref.watch(_snapshot).loaded,
        ),
        reposProvider.overrideWithValue(ReposState(const [])),
        groupsControllerProvider.overrideWith(
          (ref) => GroupsController.ephemeral(
            GroupsState(
              groups: [
                _boardWithTabs('b', ['s1', 's2']),
              ],
              activeGroupId: 'b',
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.listen(
      desktopSessionPruneProvider,
      (_, _) {},
      fireImmediately: true,
    );
    // The ingredient the existing prune tests lack: a live reader of the whole
    // active group, exactly like split_view's `+` tooltip and AgentPicker.
    container.listen(activeGroupProvider, (_, _) {}, fireImmediately: true);

    container.read(_snapshot.notifier).state = (
      sessions: [_session('s1'), _session('s2'), _session('s3')],
      loaded: true,
    );
    await Future<void>.delayed(Duration.zero);

    // A quick-pin: an in-process membership mutation, no server frame.
    container
        .read(groupsControllerProvider.notifier)
        .addMember('b', 's3', location: const SessionLocation(projectId: 'p1'));
    await Future<void>.delayed(Duration.zero);

    // Reading it must still work: an aborted build leaves the element with no
    // state, which is what surfaces downstream as "Tried to read the state of
    // an uninitialized provider".
    expect(container.read(activeGroupProvider).members, ['s1', 's2', 's3']);
  });
}
