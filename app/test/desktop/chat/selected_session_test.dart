// Unit tests for the ref-based session/worktree selection helpers on the
// SPEC-28 workspace model. These take a [WidgetRef] rather than a [Ref], so
// tests capture one from a bare [Consumer] button press.
import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/groups/placement.dart' show boundSessionIds;
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/transport/protocol.dart';

/// A connection that answers every request instantly — so the fire-and-forget
/// archive on tab close leaves no pending timeout Timer in widget tests.
class _FastConn extends ConnectionController {
  _FastConn() : super(const _NoStore());
  final sent = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> request(MsgType t, Map<String, dynamic> body) {
    sent.add(body);
    return Future.value(const {});
  }
}

class _NoStore implements SecureStore {
  const _NoStore();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

Session _session(
  String id, {
  String? worktreePath,
  String? branch,
  bool pending = false,
}) => Session(
  id: id,
  projectId: 'p1',
  agent: 'codex',
  title: '',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  branch: branch,
  worktreePath: worktreePath,
  pending: pending,
);

const _wtA = SelectedWorktree(projectId: 'p1', path: '/tmp/wt-a', branch: 'a');

WorkspaceController _workspace(ProviderContainer c) =>
    c.read(workspaceControllerProvider.notifier);

/// The active split's active tab (via the same walk the providers use).
Tab _activeTab(ProviderContainer c) =>
    activeTab(c.read(workspaceControllerProvider))!;

/// Pumps a bare button whose press invokes [action] with a real [WidgetRef],
/// then taps it.
Future<void> _invoke(
  WidgetTester tester,
  ProviderContainer container,
  void Function(WidgetRef ref) action,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (ctx, ref, _) => TextButton(
              onPressed: () => action(ref),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pump();
}

void main() {
  setUp(resetNodeIds);

  // SPEC-30 Lane 7 / decision 7: unpin-vs-archive is a property of the ACTIVE
  // GROUP'S KIND, not of the affordance — so the tab ✕ and ⌘⇧W cannot disagree.
  group('closeTabAndArchive by group kind (decision 7)', () {
    /// Runs [close] against a container whose active group is [group], with
    /// session `s1` bound to the active tab, and reports what was sent.
    Future<(_FastConn, GroupsController)> runClose(
      WidgetTester tester,
      Group group,
      void Function(WidgetRef ref) close,
    ) async {
      final conn = _FastConn();
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith((_) => conn),
          sessionsProvider.overrideWithValue(SessionsState([_session('s1')])),
          groupsControllerProvider.overrideWith(
            (ref) => GroupsController.ephemeral(
              GroupsState(groups: [group], activeGroupId: group.id),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      _workspace(container).revealSession('s1');
      await _invoke(tester, container, close);
      await tester.pumpAndSettle();
      return (conn, container.read(groupsControllerProvider.notifier));
    }

    Group board() => Group.board(
      id: 'b1',
      label: 'Ship',
      members: const ['s1'],
      tree: WorkspaceController.seedWorkspace(),
    );
    Group worktree() => Group.worktree(
      id: 'g1',
      projectId: 'p1',
      worktreePath: '/tmp/wt/feat-x',
      label: 'feat/x',
      tree: WorkspaceController.seedWorkspace(),
    );

    testWidgets('on a board the tab ✕ unpins and never archives', (
      tester,
    ) async {
      final (conn, groups) = await runClose(tester, board(), (ref) {
        final state = ref.read(workspaceControllerProvider);
        final tab = activeTab(state)!;
        closeTabAndArchive(ref, state.activeSplitId, tab.id, tab.sessionId);
      });

      expect(groups.groupById('b1')!.members, isEmpty, reason: 'unpinned');
      expect(
        conn.sent.where((m) => m['kind'] == 'session.archive'),
        isEmpty,
        reason: 'the agent keeps running',
      );
    });

    testWidgets('in a worktree group the tab ✕ archives (unchanged)', (
      tester,
    ) async {
      final (conn, _) = await runClose(tester, worktree(), (ref) {
        final state = ref.read(workspaceControllerProvider);
        final tab = activeTab(state)!;
        closeTabAndArchive(ref, state.activeSplitId, tab.id, tab.sessionId);
      });

      expect(conn.sent.where((m) => m['kind'] == 'session.archive').length, 1);
    });

    testWidgets('⌘⇧W agrees with the ✕ on a board (one shared path)', (
      tester,
    ) async {
      final (conn, groups) = await runClose(tester, board(), closeActiveTab);
      expect(groups.groupById('b1')!.members, isEmpty);
      expect(conn.sent.where((m) => m['kind'] == 'session.archive'), isEmpty);
    });

    testWidgets('⌘⇧W agrees with the ✕ in a worktree group', (tester) async {
      final (conn, _) = await runClose(tester, worktree(), closeActiveTab);
      expect(conn.sent.where((m) => m['kind'] == 'session.archive').length, 1);
    });
  });

  group('selectSessionExclusive (decision 6 reveal)', () {
    testWidgets('binds the session into the active split\'s empty tab', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState([_session('s1')])),
        ],
      );
      addTearDown(container.dispose);

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      expect(container.read(selectedSessionProvider), 's1');
      expect(_activeTab(container).sessionId, 's1');
    });

    testWidgets('focuses an already-open session instead of duplicating it '
        '(decision 5)', (tester) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(
            SessionsState([_session('s1'), _session('s2')]),
          ),
        ],
      );
      addTearDown(container.dispose);
      // s1 in the first split; a second split hosts s2 and is active.
      _workspace(container).revealSession('s1');
      _workspace(container).divideActive(Axis.horizontal);
      _workspace(container).revealSession('s2');
      expect(container.read(selectedSessionProvider), 's2');

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      // Reveal focused the existing s1 tab (active selection is s1 again); s1
      // still appears exactly once in the tree.
      expect(container.read(selectedSessionProvider), 's1');
      final located = findTab(
        container.read(workspaceControllerProvider).root,
        's1',
      );
      expect(located, isNotNull);
    });
  });

  group('selectWorktree', () {
    testWidgets('opens a starter tab hinted with the worktree (no swap)', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(const [])),
        ],
      );
      addTearDown(container.dispose);

      await _invoke(tester, container, (ref) {
        selectWorktree(ref, _wtA);
      });

      final tab = _activeTab(container);
      expect(tab.sessionId, isNull);
      expect(tab.worktree, _wtA);
      expect(container.read(selectedWorktreeProvider), _wtA);
      expect(container.read(selectedSessionProvider), isNull);
    });
  });

  group('closeActiveSplit / closeActiveTab', () {
    testWidgets('closeActiveTab collapses an emptied split back to a sibling', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith((_) => _FastConn()),
          sessionsProvider.overrideWithValue(
            SessionsState([_session('s1'), _session('s2')]),
          ),
        ],
      );
      addTearDown(container.dispose);
      _workspace(container).revealSession('s1');
      _workspace(container).divideActive(Axis.horizontal);
      _workspace(container).revealSession('s2'); // active split hosts s2 only

      await _invoke(tester, container, closeActiveTab);

      // The active split had a single tab (s2) → closing it collapsed the
      // split into the sibling that hosts s1.
      expect(container.read(workspaceControllerProvider).root, isA<Split>());
      expect(container.read(selectedSessionProvider), 's1');
    });

    testWidgets('closeActiveTab archives the orphaned session (SPEC-29)', (
      tester,
    ) async {
      // SPEC-30 decision 7 made this kind-dependent: archiving is the WORKTREE
      // group's behaviour (membership is derived, so ending the session is the
      // only way off that canvas). On a board the same path unpins instead —
      // covered in "closeTabAndArchive by group kind".
      final conn = _FastConn();
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith((_) => conn),
          sessionsProvider.overrideWithValue(SessionsState([_session('s1')])),
          groupsControllerProvider.overrideWith(
            (ref) => GroupsController.ephemeral(
              GroupsState(
                groups: [
                  Group.worktree(
                    id: 'g1',
                    projectId: 'p1',
                    worktreePath: '/tmp/wt/feat-x',
                    label: 'feat/x',
                    tree: WorkspaceController.seedWorkspace(),
                  ),
                ],
                activeGroupId: 'g1',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      _workspace(container).revealSession('s1');

      await _invoke(tester, container, closeActiveTab);

      // Closing the sole tab orphans s1 → it is archived (soft, recoverable).
      final archive = conn.sent.firstWhere(
        (b) => b['kind'] == 'session.archive',
        orElse: () => const {},
      );
      expect(archive['sessionId'], 's1');
    });

    testWidgets('closeActiveTab does NOT archive an untouched draft (SPEC-29)', (
      tester,
    ) async {
      final conn = _FastConn();
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith((_) => conn),
          groupsControllerProvider.overrideWith(
            (ref) => GroupsController.ephemeral(
              GroupsState(
                groups: [
                  Group.worktree(
                    id: 'g1',
                    projectId: 'p1',
                    worktreePath: '/tmp/wt/feat-x',
                    label: 'feat/x',
                    tree: WorkspaceController.seedWorkspace(),
                  ),
                ],
                activeGroupId: 'g1',
              ),
            ),
          ),
          sessionsProvider.overrideWithValue(
            SessionsState([_session('d1', pending: true)]),
          ),
        ],
      );
      addTearDown(container.dispose);
      _workspace(container).revealSession('d1');

      await _invoke(tester, container, closeActiveTab);

      // A never-started draft has no history worth preserving — closing its tab
      // must not archive it (no empty entry in the Archived list).
      expect(conn.sent.any((b) => b['kind'] == 'session.archive'), isFalse);
    });

    testWidgets('closeActiveSplit is a no-op on the sole split', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState([_session('s1')])),
        ],
      );
      addTearDown(container.dispose);
      _workspace(container).revealSession('s1');
      final before = container.read(workspaceControllerProvider);

      await _invoke(tester, container, closeActiveSplit);

      expect(container.read(workspaceControllerProvider), before);
    });
  });

  group('selectSessionExclusive navigation (decision 15 a→d)', () {
    // A container with an explicit groups state, so navigation can be observed
    // switching (or not switching) the active group.
    ProviderContainer nav({
      required List<Group> groups,
      required List<Session> sessions,
      required String activeGroupId,
    }) {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(sessions)),
          groupsControllerProvider.overrideWith(
            (ref) => GroupsController.ephemeral(
              GroupsState(groups: groups, activeGroupId: activeGroupId),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Group board(String id, List<String> members) =>
        Group.board(id: id, label: id, members: members, tree: seed());
    Group wt(String id, String path, {String? branch}) => Group.worktree(
      id: id,
      projectId: 'p1',
      worktreePath: path,
      label: branch ?? path.split('/').last,
      tree: seed(),
    );

    testWidgets('(a) already a member of the active group → no switch', (
      tester,
    ) async {
      final container = nav(
        groups: [
          board('b1', ['s1']),
          wt('g2', '/tmp/wt/feat-x'),
        ],
        sessions: [_session('s1', worktreePath: '/tmp/wt/feat-x')],
        activeGroupId: 'b1',
      );

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      expect(
        container.read(groupsControllerProvider).activeGroupId,
        'b1',
        reason:
            'no group switch when the session is already in the active view',
      );
      expect(container.read(selectedSessionProvider), 's1');
    });

    testWidgets('(b) else its own worktree group when open', (tester) async {
      final container = nav(
        groups: [wt('g1', '/tmp/wt/main'), wt('g2', '/tmp/wt/feat-x')],
        sessions: [_session('s1', worktreePath: '/tmp/wt/feat-x')],
        activeGroupId: 'g1',
      );

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      expect(container.read(groupsControllerProvider).activeGroupId, 'g2');
      expect(container.read(selectedSessionProvider), 's1');
    });

    testWidgets('(c) else any open board holding it', (tester) async {
      final container = nav(
        groups: [
          wt('g1', '/tmp/wt/main'),
          board('b1', ['s1']),
        ],
        // s1 is on feat-x, but no worktree group is open for feat-x — so (b)
        // misses and resolution falls through to the board.
        sessions: [_session('s1', worktreePath: '/tmp/wt/feat-x')],
        activeGroupId: 'g1',
      );

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      expect(container.read(groupsControllerProvider).activeGroupId, 'b1');
      expect(container.read(selectedSessionProvider), 's1');
    });

    testWidgets('(d) else mints the session\'s worktree group', (tester) async {
      final container = nav(
        groups: [wt('g1', '/tmp/wt/main')],
        sessions: [
          _session('s1', worktreePath: '/tmp/wt/feat-x', branch: 'feat/x'),
        ],
        activeGroupId: 'g1',
      );

      await _invoke(tester, container, (ref) {
        selectSessionExclusive(ref, 's1');
      });

      final groups = container.read(groupsControllerProvider);
      final minted = groups.groups.firstWhere(
        (g) => g.isScopedTo(projectId: 'p1', worktreePath: '/tmp/wt/feat-x'),
      );
      expect(
        groups.activeGroupId,
        minted.id,
        reason: 'the minted group is active',
      );
      expect(minted.kind, GroupKind.worktree);
      expect(container.read(selectedSessionProvider), 's1');
    });

    testWidgets(
      'clicking a foreign-branch session NEVER converts the active worktree '
      'group (decision 15 vs decision 4)',
      (tester) async {
        // The user is scoped to feat/login; they click a `main` agent.
        final container = nav(
          groups: [wt('gLogin', '/tmp/wt/login', branch: 'feat/login')],
          sessions: [
            _session('sMain', worktreePath: '/tmp/wt/main', branch: 'main'),
          ],
          activeGroupId: 'gLogin',
        );

        await _invoke(tester, container, (ref) {
          selectSessionExclusive(ref, 'sMain');
        });

        final groups = container.read(groupsControllerProvider);
        final login = groups.groups.firstWhere((g) => g.id == 'gLogin');
        // The group we left is untouched: still a worktree group, never a board.
        expect(login.kind, GroupKind.worktree);
        // And decision 4's ugly auto-name never appeared — navigation did not
        // add a member, so no conversion happened.
        expect(
          groups.groups.where((g) => g.label == 'feat/login +1'),
          isEmpty,
          reason: 'a session click must never trigger a board conversion',
        );
        // We travelled to main\'s freshly minted worktree group instead.
        final main = groups.groups.firstWhere(
          (g) => g.isScopedTo(projectId: 'p1', worktreePath: '/tmp/wt/main'),
        );
        expect(groups.activeGroupId, main.id);
        expect(main.kind, GroupKind.worktree);
      },
    );
  });

  group('workspaceControllerProvider follows group-layer tree edits', () {
    test('unpinning a member on the ACTIVE board prunes its tab from the '
        'canvas (no resurrection on the next commit)', () {
      const tree = WorkspaceState(
        root: Split(
          id: 'sp0',
          tabs: [
            Tab(id: 't1', sessionId: 's1'),
            Tab(id: 't2', sessionId: 's2'),
          ],
          activeTabId: 't1',
        ),
        activeSplitId: 'sp0',
      );
      final board = Group.board(
        id: 'b1',
        label: 'Board',
        members: const ['s1', 's2'],
        tree: tree,
      );
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith((_) => _FastConn()),
          sessionsProvider.overrideWithValue(
            SessionsState([_session('s1'), _session('s2')]),
          ),
          groupsControllerProvider.overrideWith(
            (ref) => GroupsController.ephemeral(
              GroupsState(groups: [board], activeGroupId: 'b1'),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      // The canvas seeds from the active board's tree.
      expect(boundSessionIds(container.read(workspaceControllerProvider)), [
        's1',
        's2',
      ]);

      // Unpin s1 from the groups layer (as AgentPicker._toggle does on the
      // active board): it prunes s1's tab from the board's tree.
      container
          .read(groupsControllerProvider.notifier)
          .removeMember('b1', 's1');

      // The rendered canvas follows the edit rather than keeping a stale tree
      // that would re-commit and resurrect the pruned tab.
      expect(boundSessionIds(container.read(workspaceControllerProvider)), [
        's2',
      ]);
    });
  });
}

WorkspaceState seed() => WorkspaceController.seedWorkspace();
