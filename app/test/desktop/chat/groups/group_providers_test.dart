// SPEC-tab-groups — the shared seam: membership resolution, placement mode, and the
// decision-15 "which group already holds this session?" lookup.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/group_providers.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session(String id, {String? worktreePath, String projectId = 'p1'}) =>
    Session(
      id: id,
      projectId: projectId,
      agent: 'pi',
      title: id,
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
      worktreePath: worktreePath,
    );

Group _wt(String id, String path) => Group.worktree(
  id: id,
  projectId: 'p1',
  worktreePath: path,
  label: path.split('/').last,
  tree: WorkspaceController.seedWorkspace(),
);

Group _board(String id, List<String> members) => Group.board(
  id: id,
  label: id,
  members: members,
  tree: WorkspaceController.seedWorkspace(),
);

/// A worktree group scoped to [path] whose stored tree already hosts a tab for
/// [hostsSessionId] — the shape that exercises groupHolding's (a′) branch.
Group _wtHosting(String id, String path, String hostsSessionId) =>
    Group.worktree(
      id: id,
      projectId: 'p1',
      worktreePath: path,
      label: path.split('/').last,
      tree: WorkspaceState(
        root: Split(
          id: 'split-$id',
          tabs: [Tab(id: 'tab-$id', sessionId: hostsSessionId)],
          activeTabId: 'tab-$id',
        ),
        activeSplitId: 'split-$id',
      ),
    );

ProviderContainer _container({
  required List<Group> groups,
  required List<Session> sessions,
  String? activeGroupId,
  PreferencesController? prefs,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
      groupsControllerProvider.overrideWith(
        (ref) => GroupsController.ephemeral(
          GroupsState(
            groups: groups,
            activeGroupId: activeGroupId ?? groups.first.id,
          ),
        ),
      ),
      if (prefs != null)
        preferencesControllerProvider.overrideWith((ref) => prefs),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('groupMembersProvider', () {
    test('a worktree group derives its members from the live session list', () {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x')],
        sessions: [
          _session('s1', worktreePath: '/tmp/wt/feat-x'),
          _session('s2', worktreePath: '/tmp/wt/main'),
          _session('s3', worktreePath: '/tmp/wt/feat-x'),
          _session('s4'), // no worktree yet — in nobody's scope
        ],
      );
      expect(c.read(groupMembersProvider('g1')), ['s1', 's3']);
    });

    test('scope includes the project, not just the path', () {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x')],
        sessions: [
          _session('s1', worktreePath: '/tmp/wt/feat-x'),
          _session('s2', worktreePath: '/tmp/wt/feat-x', projectId: 'other'),
        ],
      );
      expect(c.read(groupMembersProvider('g1')), ['s1']);
    });

    test('a board keeps its own order and drops vanished sessions', () {
      final c = _container(
        groups: [
          _board('b1', ['s3', 's1', 'gone']),
        ],
        sessions: [_session('s1'), _session('s3')],
      );
      expect(c.read(groupMembersProvider('b1')), ['s3', 's1']);
    });

    test('an unknown group has no members rather than throwing', () {
      final c = _container(groups: [_board('b1', const [])], sessions: []);
      expect(c.read(groupMembersProvider('ghost')), isEmpty);
    });
  });

  group('layoutModeProvider (decision 9)', () {
    test('follows the threshold when the group has no override', () {
      final sessions = [
        for (var i = 0; i < 3; i++)
          _session('s$i', worktreePath: '/tmp/wt/feat-x'),
      ];
      // 3 shown, threshold 3 → the next one lands as a tab.
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x')],
        sessions: sessions,
      );
      expect(c.read(layoutModeProvider('g1')), LayoutMode.tabs);

      // 2 shown → still splitting.
      final c2 = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x')],
        sessions: sessions.take(2).toList(),
      );
      expect(c2.read(layoutModeProvider('g1')), LayoutMode.split);
    });

    test('a raised threshold moves the boundary', () async {
      final prefs = PreferencesController.ephemeral();
      await prefs.set(autoSplitThresholdPreference, 5);
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x')],
        sessions: [
          for (var i = 0; i < 4; i++)
            _session('s$i', worktreePath: '/tmp/wt/feat-x'),
        ],
        prefs: prefs,
      );
      expect(c.read(layoutModeProvider('g1')), LayoutMode.split);
    });

    test('an override always wins over the threshold', () {
      final pinned = _wt('g1', '/tmp/wt/feat-x').withLayout(LayoutMode.split);
      final c = _container(
        groups: [pinned],
        sessions: [
          for (var i = 0; i < 9; i++)
            _session('s$i', worktreePath: '/tmp/wt/feat-x'),
        ],
      );
      expect(c.read(layoutModeProvider('g1')), LayoutMode.split);
    });
  });

  group('groupHolding (decision 15)', () {
    List<String> Function(String) membersOf(ProviderContainer c) =>
        (id) => c.read(groupMembersProvider(id));

    test('(a) the active group wins when it is already a member', () {
      final c = _container(
        groups: [
          _board('b1', ['s1']),
          _wt('g2', '/tmp/wt/feat-x'),
        ],
        sessions: [_session('s1', worktreePath: '/tmp/wt/feat-x')],
        activeGroupId: 'b1',
      );
      final held = groupHolding(
        c.read(groupsControllerProvider),
        _session('s1', worktreePath: '/tmp/wt/feat-x'),
        membersOf(c),
      );
      expect(
        held,
        'b1',
        reason: 'no switch when you are already looking at it',
      );
    });

    test("(a′) a group whose tree already hosts the session's tab, even when "
        'the session is in no scope and on no board', () {
      // The New-session flow: a freshly spawned session, no server-reported
      // worktree yet (so in nobody's scope) and pinned to no board, but its tab
      // already lives in the group it was started from. It must resolve to that
      // group rather than falling through to (d)/null.
      final c = _container(
        groups: [
          _wt('g1', '/tmp/wt/main'),
          _wtHosting('g2', '/tmp/wt/other', 's1'),
        ],
        sessions: [_session('s1')], // worktreePath: null → in no scope
        activeGroupId: 'g1',
      );
      expect(
        groupHolding(
          c.read(groupsControllerProvider),
          _session('s1'),
          membersOf(c),
        ),
        'g2',
        reason: 'the hosting group wins over falling through to null',
      );
    });

    test('(b) else its own worktree group', () {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/main'), _wt('g2', '/tmp/wt/feat-x')],
        sessions: [_session('s1', worktreePath: '/tmp/wt/feat-x')],
        activeGroupId: 'g1',
      );
      expect(
        groupHolding(
          c.read(groupsControllerProvider),
          _session('s1', worktreePath: '/tmp/wt/feat-x'),
          membersOf(c),
        ),
        'g2',
      );
    });

    test('(c) else a board holding it', () {
      final c = _container(
        groups: [
          _wt('g1', '/tmp/wt/main'),
          _board('b1', ['s1']),
        ],
        sessions: [_session('s1', worktreePath: '/tmp/wt/feat-x')],
        activeGroupId: 'g1',
      );
      expect(
        groupHolding(
          c.read(groupsControllerProvider),
          _session('s1', worktreePath: '/tmp/wt/feat-x'),
          membersOf(c),
        ),
        'b1',
      );
    });

    test('(d) else null — the caller mints its worktree group', () {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/main')],
        sessions: [_session('s1', worktreePath: '/tmp/wt/feat-x')],
      );
      expect(
        groupHolding(
          c.read(groupsControllerProvider),
          _session('s1', worktreePath: '/tmp/wt/feat-x'),
          membersOf(c),
        ),
        isNull,
      );
    });
  });

  test('liveSessionIdsProvider mirrors the snapshot', () {
    final c = _container(
      groups: [_board('b1', const [])],
      sessions: [_session('s1'), _session('s2')],
    );
    expect(c.read(liveSessionIdsProvider), {'s1', 's2'});
  });
}
