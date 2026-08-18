/// SPEC-preview-groups decision 5 — the claim that makes replacing a preview group safe:
/// a worktree group's membership is *derived*, so re-opening a branch whose
/// preview tab was displaced brings its running agents straight back. Only the
/// hand-made split/tab arrangement is lost.
///
/// That claim is what the whole opt-in mode rests on (promotion is explicit
/// only, so a group with a live agent CAN be displaced), so it is tested against
/// the real reconcile wiring — `desktopSessionPruneProvider` plus a live reader
/// of `activeGroupProvider`, the same ingredients the app has — rather than
/// asserted in prose.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_session_prune.dart';
import 'package:makit/desktop/chat/groups/group_providers.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session(String id, String worktreePath) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: id,
  status: SessionStatus.running,
  policy: ApprovalPolicy.askOnRisky,
  branch: worktreePath.split('/').last,
  worktreePath: worktreePath,
);

final _snapshot = StateProvider<({List<Session> sessions, bool loaded})>(
  (ref) => (sessions: const [], loaded: false),
);

/// The session ids bound to tabs in the active group's canvas.
List<String> _onCanvas(ProviderContainer c) {
  final ids = <String>[];
  firstSplitWhere<bool>(c.read(workspaceControllerProvider).root, (split) {
    ids.addAll(split.tabs.map((t) => t.sessionId).nonNulls);
    return null;
  });
  return ids;
}

void main() {
  test('a displaced preview group comes back with its agents', () async {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          (ref) => SessionsState(ref.watch(_snapshot).sessions),
        ),
        sessionsLoadedProvider.overrideWith(
          (ref) => ref.watch(_snapshot).loaded,
        ),
        reposProvider.overrideWithValue(ReposState(const [])),
      ],
    );
    addTearDown(container.dispose);

    container.listen(
      desktopSessionPruneProvider,
      (_, _) {},
      fireImmediately: true,
    );
    container.listen(activeGroupProvider, (_, _) {}, fireImmediately: true);

    container.read(_snapshot.notifier).state = (
      sessions: [_session('s1', '/wt/a'), _session('s2', '/wt/b')],
      loaded: true,
    );
    await Future<void>.delayed(Duration.zero);

    final groups = container.read(groupsControllerProvider.notifier);
    final previewA = groups.openWorktreeGroup(
      projectId: 'p1',
      worktreePath: '/wt/a',
      label: 'a',
      preview: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(_onCanvas(container), ['s1'], reason: 'the agent on a is placed');

    // Click branch b: the preview tab for a is displaced, arrangement and all.
    final previewB = groups.openWorktreeGroup(
      projectId: 'p1',
      worktreePath: '/wt/b',
      label: 'b',
      preview: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(groups.groupById(previewA), isNull, reason: 'displaced');
    expect(_onCanvas(container), ['s2']);

    // Click a again: a brand-new group for the same scope — and its membership
    // is derived, so the agent that kept running is on the canvas again.
    groups.openWorktreeGroup(
      projectId: 'p1',
      worktreePath: '/wt/a',
      label: 'a',
      preview: true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(_onCanvas(container), ['s1'], reason: 'the agent is back');
    expect(
      container.read(sessionsProvider).byId('s1')?.status,
      SessionStatus.running,
      reason: 'replacing a preview group never touched the agent',
    );
    expect(groups.state.previewGroupId, isNot(previewB));
  });
}
