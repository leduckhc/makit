import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_session_prune.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/panes/split_node.dart' as node;
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session(String id, {String? worktreePath}) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: id,
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  worktreePath: worktreePath,
);

/// A repo with one worktree per [paths], so the prune's decision-7 tail can
/// watch a worktree vanish from the sidebar's repo list.
RepoInfo _repo(List<String> paths, {String id = 'p1'}) => RepoInfo(
  id: id,
  name: id,
  path: '/tmp/$id',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    for (final p in paths)
      Worktree(
        id: p,
        path: p,
        branch: p.split('/').last,
        isPrimary: false,
        insertions: 0,
        deletions: 0,
        filesChanged: 0,
        sessionIds: const [],
      ),
  ],
);

Group _wtGroup(String id, String path) => Group.worktree(
  id: id,
  projectId: 'p1',
  worktreePath: path,
  label: path.split('/').last,
  tree: WorkspaceController.seedWorkspace(),
);

/// A board whose tree already hosts a tab for each of [ids] (so we can watch
/// tabs close, not just the member list shrink).
Group _boardWithTabs(String id, List<String> ids) {
  final c = WorkspaceController(null, WorkspaceController.seedWorkspace());
  for (final sid in ids) {
    c.revealSession(sid);
  }
  return Group.board(id: id, label: id, members: ids, tree: c.state);
}

List<String> _boundIds(WorkspaceState s) => _tabSessions(s).nonNulls.toList();

/// The active split's active tab id — the pane that has focus. Bug 2's
/// "appear without stealing focus" is exactly this pair staying put.
(String, String?) _focused(WorkspaceState s) {
  final split = node.firstSplitWhere<node.Split>(
    s.root,
    (sp) => sp.id == s.activeSplitId ? sp : null,
  );
  return (s.activeSplitId, split?.activeTabId);
}

/// A board whose stored tree is the untouched seed — the exact state Bug 2
/// leaves behind when `addMember` updates membership but nothing places a pane.
Group _boardMembersOnly(String id, List<String> ids) => Group.board(
  id: id,
  label: id,
  members: ids,
  tree: WorkspaceController.seedWorkspace(),
);

final _snapshot = StateProvider<({List<Session> sessions, bool loaded})>(
  (ref) => (sessions: const [], loaded: false),
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    sessionsProvider.overrideWith(
      (ref) => SessionsState(ref.watch(_snapshot).sessions),
    ),
    sessionsLoadedProvider.overrideWith((ref) => ref.watch(_snapshot).loaded),
    // The prune provider now also listens to reposProvider (worktree-deletion
    // cleanup); override it so building it never reaches the real store /
    // ConnectionController (a keychain read that needs platform bindings).
    reposProvider.overrideWithValue(ReposState(const [])),
  ],
);

/// Mirrors the widget-level `ref.watch` in `desktop_app.dart`: the provider is
/// only alive (and listening) while something subscribes to it.
void _keepAlive(ProviderContainer container) => container.listen(
  desktopSessionPruneProvider,
  (_, _) {},
  fireImmediately: true,
);

/// Simulates a `sessions.snapshot` frame arriving from the server.
void _push(ProviderContainer container, List<Session> sessions) =>
    container.read(_snapshot.notifier).state = (
      sessions: sessions,
      loaded: true,
    );

List<String?> _tabSessions(WorkspaceState state) {
  final ids = <String?>[];
  void walk(node.SplitNode n) {
    if (n is node.Split) {
      ids.addAll(n.tabs.map((t) => t.sessionId));
    } else if (n is node.Splitter) {
      walk(n.first);
      walk(n.second);
    }
  }

  walk(state.root);
  return ids;
}

void main() {
  test('closes the tab of a session closed from another client', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ctrl = container.read(workspaceControllerProvider.notifier);
    ctrl.revealSession('a');
    ctrl.revealSession('b');
    _keepAlive(container);

    // Both sessions live on the server.
    _push(container, [_session('a'), _session('b')]);
    await Future<void>.delayed(Duration.zero);
    expect(_tabSessions(container.read(workspaceControllerProvider)), [
      'a',
      'b',
    ]);

    // 'b' is closed/quit elsewhere: the next snapshot drops it, so its tab
    // must go too instead of lingering as an empty pane.
    _push(container, [_session('a')]);
    await Future<void>.delayed(Duration.zero);
    expect(_tabSessions(container.read(workspaceControllerProvider)), ['a']);
  });

  test('drops restored tabs whose sessions are gone from the server', () async {
    final container = _container();
    addTearDown(container.dispose);
    final ctrl = container.read(workspaceControllerProvider.notifier);
    // A persisted layout from a previous run: two of its sessions no longer
    // exist server-side.
    ctrl.revealSession('gone-1');
    ctrl.revealSession('alive');
    ctrl.revealSession('gone-2');
    _keepAlive(container);

    _push(container, [_session('alive')]);
    await Future<void>.delayed(Duration.zero);

    expect(_tabSessions(container.read(workspaceControllerProvider)), [
      'alive',
    ]);
  });

  test('keeps tabs until the first snapshot has arrived', () async {
    final container = _container();
    addTearDown(container.dispose);
    container.read(workspaceControllerProvider.notifier).revealSession('a');
    _keepAlive(container);
    await Future<void>.delayed(Duration.zero);

    // No snapshot yet (offline / still connecting): an empty session list is
    // "unknown", not "the server has none" — the layout must survive.
    expect(_tabSessions(container.read(workspaceControllerProvider)), ['a']);
  });

  test('an empty snapshot prunes every session tab', () async {
    final container = _container();
    addTearDown(container.dispose);
    container.read(workspaceControllerProvider.notifier).revealSession('a');
    _keepAlive(container);

    _push(container, const []);
    await Future<void>.delayed(Duration.zero);

    expect(_tabSessions(container.read(workspaceControllerProvider)), [null]);
  });

  group('SPEC-30 lane 3', () {
    // A prune container with an explicit groups state and a live repos list, so
    // decisions 5/6/7 can be driven end to end.
    ProviderContainer groupsContainer(
      GroupsState groups, {
      List<RepoInfo> repos = const [],
    }) {
      final reposState = StateProvider<List<RepoInfo>>((ref) => repos);
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWith(
            (ref) => SessionsState(ref.watch(_snapshot).sessions),
          ),
          sessionsLoadedProvider.overrideWith(
            (ref) => ref.watch(_snapshot).loaded,
          ),
          reposProvider.overrideWith(
            (ref) => ReposState(ref.watch(reposState)),
          ),
          groupsControllerProvider.overrideWith(
            (ref) => GroupsController.ephemeral(groups),
          ),
        ],
      );
      // Expose the repos knob via a container-scoped read.
      _reposKnob[container] = reposState;
      // Evict alongside the container so the map doesn't retain disposed
      // containers (and their providers) for the whole test session.
      addTearDown(() => _reposKnob.remove(container));
      return container;
    }

    test('decision 6: a vanished session unpins from EVERY board that '
        'holds it, not just the active one', () async {
      // Two boards both curate the same session 's' plus a survivor 'keep'.
      final b1 = _boardWithTabs('b1', ['s', 'keep']);
      final b2 = _boardWithTabs('b2', ['s', 'keep']);
      final container = groupsContainer(
        GroupsState(groups: [b1, b2], activeGroupId: 'b1'),
      );
      addTearDown(container.dispose);
      _keepAlive(container);

      _push(container, [_session('keep')]);
      await Future<void>.delayed(Duration.zero);

      final groups = container.read(groupsControllerProvider);
      final gb1 = groups.groups.firstWhere((g) => g.id == 'b1');
      final gb2 = groups.groups.firstWhere((g) => g.id == 'b2');

      // The member list of BOTH boards drops 's' (this is the whole point of
      // decision 6 — a broken prune that only touched the active board would
      // leave gb2.members == ['s', 'keep'] and fail here).
      expect(gb1.members, ['keep']);
      expect(gb2.members, [
        'keep',
      ], reason: 'every board unpins, not just active');

      // The active board also closes the dead tab (no dead tile on the canvas).
      expect(_boundIds(container.read(workspaceControllerProvider)), ['keep']);
    });

    test(
      'decision 6: an INACTIVE board drops the vanished session\'s tab too',
      () async {
        // Found by the QA pass and independently by review: the prune closed tabs
        // only in the ACTIVE workspace, so an inactive board carried a tab bound
        // to a gone session and showed a dead tile the moment you activated it.
        // Fixed by making `removeMember` drop the tab as well — membership and
        // tree are not allowed to disagree.
        final b1 = _boardWithTabs('b1', ['s', 'keep']);
        final b2 = _boardWithTabs('b2', ['s', 'keep']);
        final container = groupsContainer(
          GroupsState(groups: [b1, b2], activeGroupId: 'b1'),
        );
        addTearDown(container.dispose);
        _keepAlive(container);

        _push(container, [_session('keep')]);
        await Future<void>.delayed(Duration.zero);

        final gb2 = container
            .read(groupsControllerProvider)
            .groups
            .firstWhere((g) => g.id == 'b2');
        expect(_boundIds(gb2.tree), ['keep']);
      },
    );

    test('decision 5: a new session on the active worktree group\'s branch '
        'joins the canvas without switching groups; one on another branch '
        'changes neither', () async {
      final gA = _wtGroup('gA', '/tmp/wt/A');
      final container = groupsContainer(
        GroupsState(groups: [gA], activeGroupId: 'gA'),
      );
      addTearDown(container.dispose);
      _keepAlive(container);

      // A session appears on branch A (the active group's scope): it joins the
      // derived membership and lands on the canvas.
      _push(container, [_session('sA', worktreePath: '/tmp/wt/A')]);
      await Future<void>.delayed(Duration.zero);
      expect(_boundIds(container.read(workspaceControllerProvider)), ['sA']);
      expect(container.read(groupsControllerProvider).activeGroupId, 'gA');

      // Now a session appears on a DIFFERENT branch B. It is out of scope, so
      // it must not land on the canvas and must not switch the active group.
      _push(container, [
        _session('sA', worktreePath: '/tmp/wt/A'),
        _session('sB', worktreePath: '/tmp/wt/B'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(_boundIds(container.read(workspaceControllerProvider)), [
        'sA',
      ], reason: 'a foreign-branch session never joins the canvas');
      expect(
        container.read(groupsControllerProvider).activeGroupId,
        'gA',
        reason: 'a foreign-branch session never switches the active group',
      );
    });

    test('bug 2: pinning a session to the active board places a pane for it '
        'and leaves existing panes — and focus — where they were', () async {
      // A board already showing s1 and s2 (two tabs in one split; the last
      // revealed, s2, is focused).
      final b = _boardWithTabs('b', ['s1', 's2']);
      final container = groupsContainer(
        GroupsState(groups: [b], activeGroupId: 'b'),
      );
      addTearDown(container.dispose);
      _keepAlive(container);

      _push(container, [_session('s1'), _session('s2')]);
      await Future<void>.delayed(Duration.zero);
      final focusBefore = _focused(container.read(workspaceControllerProvider));

      // The user pins s3 (an explicit add): it must appear on the canvas...
      container
          .read(groupsControllerProvider.notifier)
          .addMember(
            'b',
            's3',
            location: const SessionLocation(projectId: 'p1'),
          );
      _push(container, [_session('s1'), _session('s2'), _session('s3')]);
      await Future<void>.delayed(Duration.zero);

      expect(_boundIds(container.read(workspaceControllerProvider)).toSet(), {
        's1',
        's2',
        's3',
      }, reason: 'the pinned agent lands on the board canvas');
      expect(
        _focused(container.read(workspaceControllerProvider)),
        focusBefore,
        reason: 'a pinned agent appears without stealing focus',
      );
    });

    test('pinning an existing session places its pane immediately, without '
        'waiting for the next sessions snapshot', () async {
      // Everything the server knows is already on the wire: s3 exists, it is
      // just not on this board yet. Quick-pin is an in-process membership
      // mutation, so nothing else will arrive to trigger a reconcile.
      final b = _boardWithTabs('b', ['s1', 's2']);
      final container = groupsContainer(
        GroupsState(groups: [b], activeGroupId: 'b'),
      );
      addTearDown(container.dispose);
      _keepAlive(container);

      _push(container, [_session('s1'), _session('s2'), _session('s3')]);
      await Future<void>.delayed(Duration.zero);
      final focusBefore = _focused(container.read(workspaceControllerProvider));

      container
          .read(groupsControllerProvider.notifier)
          .addMember(
            'b',
            's3',
            location: const SessionLocation(projectId: 'p1'),
          );
      await Future<void>.delayed(Duration.zero);

      expect(_boundIds(container.read(workspaceControllerProvider)).toSet(), {
        's1',
        's2',
        's3',
      }, reason: 'the pinned agent shows up right away');
      expect(
        _focused(container.read(workspaceControllerProvider)),
        focusBefore,
        reason: 'a pinned agent appears without stealing focus',
      );
    });

    test(
      'a pin and a sessions snapshot landing in the SAME frame both '
      'reconcile, without tripping Riverpod\'s one-rebuild-per-frame rule',
      () async {
        final b = _boardWithTabs('b', ['s1']);
        final container = groupsContainer(
          GroupsState(groups: [b], activeGroupId: 'b'),
        );
        addTearDown(container.dispose);
        _keepAlive(container);

        _push(container, [_session('s1')]);
        await Future<void>.delayed(Duration.zero);

        // Two reconcile triggers, one turn: the membership listener and the
        // sessions listener. Reading a derived provider from both is what threw
        // `Bad state: Tried to rebuild Provider<Group> multiple times in the same
        // frame`, which is why the reconciler resolves membership itself.
        container
            .read(groupsControllerProvider.notifier)
            .addMember(
              'b',
              's2',
              location: const SessionLocation(projectId: 'p1'),
            );
        _push(container, [_session('s1'), _session('s2'), _session('s3')]);
        await Future<void>.delayed(Duration.zero);

        expect(_boundIds(container.read(workspaceControllerProvider)).toSet(), {
          's1',
          's2',
        }, reason: 's3 exists but was never pinned, so it stays off the board');
      },
    );

    test(
      'bug 2: close a board with 3 members then reopen — all 3 return '
      'to its canvas even though the stored tree was never populated',
      () async {
        // A neighbour group so the board is not the last one (close refuses that).
        final keep = _wtGroup('keep', '/tmp/wt/keep');
        final board = _boardMembersOnly('b', ['s1', 's2', 's3']);
        final container = groupsContainer(
          GroupsState(groups: [keep, board], activeGroupId: 'b'),
        );
        addTearDown(container.dispose);
        _keepAlive(container);

        final ctrl = container.read(groupsControllerProvider.notifier);
        ctrl.closeGroup('b');
        ctrl.reopenBoard('b', liveSessionIds: const {'s1', 's2', 's3'});
        _push(container, [_session('s1'), _session('s2'), _session('s3')]);
        await Future<void>.delayed(Duration.zero);

        expect(_boundIds(container.read(workspaceControllerProvider)).toSet(), {
          's1',
          's2',
          's3',
        }, reason: 'a reopened board shows its surviving members');
      },
    );

    test('bug 2: a board closed-while-closed reopens showing only its '
        'survivors (the ghost is filtered on the way back in)', () async {
      final keep = _wtGroup('keep', '/tmp/wt/keep');
      final board = _boardMembersOnly('b', ['s1', 's2', 's3']);
      final container = groupsContainer(
        GroupsState(groups: [keep, board], activeGroupId: 'b'),
      );
      addTearDown(container.dispose);
      _keepAlive(container);

      final ctrl = container.read(groupsControllerProvider.notifier);
      ctrl.closeGroup('b');
      // s3 was closed while the board was closed — reopen filters it out.
      ctrl.reopenBoard('b', liveSessionIds: const {'s1', 's2'});
      _push(container, [_session('s1'), _session('s2')]);
      await Future<void>.delayed(Duration.zero);

      expect(_boundIds(container.read(workspaceControllerProvider)).toSet(), {
        's1',
        's2',
      }, reason: 'survivors are on the canvas and the dead member is gone');
    });

    test('decision 7 tail: deleting the active group\'s worktree closes it '
        'and focus falls to the NEIGHBOUR group, not the first', () async {
      // Three worktree groups; the active one is last, so "neighbour" (g1) and
      // "first" (g0) are different — a lazy first-focus implementation fails.
      final g0 = _wtGroup('g0', '/tmp/wt/0');
      final g1 = _wtGroup('g1', '/tmp/wt/1');
      final g2 = _wtGroup('g2', '/tmp/wt/2');
      final container = groupsContainer(
        GroupsState(groups: [g0, g1, g2], activeGroupId: 'g2'),
        repos: [
          _repo(['/tmp/wt/0', '/tmp/wt/1', '/tmp/wt/2']),
        ],
      );
      addTearDown(container.dispose);
      _keepAlive(container);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(groupsControllerProvider).activeGroupId, 'g2');

      // The worktree backing g2 is deleted from the sidebar's repo list.
      container.read(_reposKnob[container]!.notifier).state = [
        _repo(['/tmp/wt/0', '/tmp/wt/1']),
      ];
      await Future<void>.delayed(Duration.zero);

      final groups = container.read(groupsControllerProvider);
      expect(groups.groups.map((g) => g.id), [
        'g0',
        'g1',
      ], reason: 'the deleted worktree\'s group is dropped');
      expect(
        groups.activeGroupId,
        'g1',
        reason:
            'focus falls to the neighbour (index-1), never always the first',
      );
    });
  });
}

/// Per-container handle to the repos knob, so a test can push a new repo list
/// after construction without threading the provider through every call.
final Map<ProviderContainer, StateProvider<List<RepoInfo>>> _reposKnob = {};
