// SPEC-30 Lane 5 — the group bar and membership bar widgets.
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/group_bar.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart'
    show kTitleBarStripHeight;
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

Session _session(
  String id, {
  String? worktreePath,
  String projectId = 'p1',
  SessionStatus status = SessionStatus.idle,
}) => Session(
  id: id,
  projectId: projectId,
  agent: 'pi',
  title: id,
  status: status,
  policy: ApprovalPolicy.askOnRisky,
  worktreePath: worktreePath,
);

Group _wt(String id, String path, {String? label}) => Group.worktree(
  id: id,
  projectId: 'p1',
  worktreePath: path,
  label: label ?? path.split('/').last,
  tree: WorkspaceController.seedWorkspace(),
);

Group _board(String id, List<String> members, {String? label}) => Group.board(
  id: id,
  label: label ?? id,
  members: members,
  tree: WorkspaceController.seedWorkspace(),
);

/// A repo `p1` whose single worktree at [path] currently sits on [branch] —
/// used to prove the tab title tracks the live branch, not the stored label.
RepoInfo _repoWithWorktree(String path, String branch) => RepoInfo(
  id: 'p1',
  name: 'makit',
  path: '/tmp/p1',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    Worktree(
      id: 'w1',
      path: path,
      branch: branch,
      isPrimary: false,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: const [],
    ),
  ],
);

ProviderContainer _container({
  required List<Group> groups,
  required List<Session> sessions,
  String? activeGroupId,
  List<ClosedBoard> recentlyClosed = const [],
  List<RepoInfo> repos = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
      reposProvider.overrideWithValue(ReposState(repos)),
      groupsControllerProvider.overrideWith(
        (ref) => GroupsController.ephemeral(
          GroupsState(
            groups: groups,
            activeGroupId: activeGroupId ?? groups.first.id,
            recentlyClosed: recentlyClosed,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child, {
  double width = 800,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('GroupBar tab', () {
    testWidgets('a worktree group renders its swatch, count, and ✕ tooltip', (
      tester,
    ) async {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x', label: 'feat/x')],
        sessions: [
          _session('s1', worktreePath: '/tmp/wt/feat-x'),
          _session('s2', worktreePath: '/tmp/wt/feat-x'),
        ],
      );
      await _pump(tester, c, const GroupBar());

      expect(find.text('feat/x'), findsOneWidget);
      expect(find.byKey(const Key('groupKindSwatch')), findsOneWidget);
      expect(find.text('2'), findsOneWidget); // member count
      expect(
        find.byTooltip(
          'Close this view — the branch, its folder and its agents '
          'are untouched',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a board renders its swatch, count, and ✕ tooltip', (
      tester,
    ) async {
      final c = _container(
        groups: [
          _board('b1', ['s1'], label: 'Shipping'),
        ],
        sessions: [_session('s1')],
      );
      await _pump(tester, c, const GroupBar());

      expect(find.text('Shipping'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(
        find.byTooltip('Close this board — the list goes to Recently closed'),
        findsOneWidget,
      );
    });

    testWidgets('right-click on a board tab renames it', (tester) async {
      final c = _container(
        groups: [
          _board('b1', ['s1'], label: 'Shipping'),
        ],
        sessions: [_session('s1')],
      );
      await _pump(tester, c, const GroupBar());

      await tester.tap(find.text('Shipping'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename board'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Ship 1.0');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(
        c.read(groupsControllerProvider.notifier).groupById('b1')!.label,
        'Ship 1.0',
      );
      expect(find.text('Ship 1.0'), findsOneWidget);
    });

    testWidgets('a worktree tab has no rename menu', (tester) async {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x', label: 'feat/x')],
        sessions: const [],
      );
      await _pump(tester, c, const GroupBar());

      await tester.tap(find.text('feat/x'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Rename board'), findsNothing);
    });

    testWidgets('a worktree tab shows the live branch, not a stale label', (
      tester,
    ) async {
      // The group was minted on feat/x; the branch was later renamed to
      // feat/renamed. The group is keyed by the (unchanged) worktree path, so
      // the tab must follow the live branch rather than its stored label.
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x', label: 'feat/x')],
        sessions: const [],
        repos: [_repoWithWorktree('/tmp/wt/feat-x', 'feat/renamed')],
      );
      await _pump(tester, c, const GroupBar());

      expect(find.text('feat/renamed'), findsOneWidget);
      expect(find.text('feat/x'), findsNothing);
    });

    testWidgets('a worktree group with no members shows 0 and no live dot', (
      tester,
    ) async {
      // Clicking a branch nobody is working on is a normal thing to do; the tab
      // must render rather than assume at least one member.
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/chore-deps')],
        sessions: [],
      );
      await _pump(tester, c, const GroupBar());

      expect(find.text('0'), findsOneWidget);
      // Keyed, so this assertion cannot silently pass by matching nothing.
      expect(
        find.byKey(const Key('groupLiveDot-g1')),
        findsNothing,
        reason: 'no live dot without a running member',
      );
    });

    testWidgets('a board whose members all vanished shows 0, not stale ids', (
      tester,
    ) async {
      // Membership is filtered against the live session list, so a board left
      // holding only archived ids must not claim to have agents.
      final c = _container(
        groups: [
          _board('b1', ['gone-1', 'gone-2']),
        ],
        sessions: [],
      );
      await _pump(tester, c, const GroupBar());

      expect(find.text('0'), findsOneWidget);
      expect(find.text('2'), findsNothing);
    });

    testWidgets('a very long label is truncated, not overflowed', (
      tester,
    ) async {
      final c = _container(
        groups: [
          _wt(
            'g1',
            '/tmp/wt/long',
            label: 'feature/a-branch-name-nobody-should-have-typed-but-did',
          ),
        ],
        sessions: [],
      );
      await _pump(tester, c, const GroupBar(), width: 300);

      // No RenderFlex overflow was thrown while laying the rail out.
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(
        find.text('feature/a-branch-name-nobody-should-have-typed-but-did'),
      );
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.maxLines, 1);
    });

    testWidgets('the ✕ closes the group', (tester) async {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/a'), _board('b1', const [])],
        sessions: const [],
      );
      await _pump(tester, c, const GroupBar());

      await tester.tap(
        find.byTooltip(
          'Close this view — the branch, its folder and its agents '
          'are untouched',
        ),
      );
      await tester.pump();

      final state = c.read(groupsControllerProvider);
      expect(state.groups.map((g) => g.id), ['b1']);
    });
  });

  group('GroupBar live dot (decision: only when a member is running)', () {
    testWidgets('appears when a member session is running', (tester) async {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x')],
        sessions: [
          _session(
            's1',
            worktreePath: '/tmp/wt/feat-x',
            status: SessionStatus.running,
          ),
        ],
      );
      await _pump(tester, c, const GroupBar());
      // No pumpAndSettle: the live dot pulses forever by design.
      expect(find.byKey(const Key('groupLiveDot-g1')), findsOneWidget);
    });

    testWidgets('is absent when no member is running', (tester) async {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/feat-x')],
        sessions: [
          _session(
            's1',
            worktreePath: '/tmp/wt/feat-x',
            status: SessionStatus.idle,
          ),
        ],
      );
      await _pump(tester, c, const GroupBar());
      expect(find.byKey(const Key('groupLiveDot-g1')), findsNothing);
    });
  });

  group('GroupBar rail (decision 12: scrolls, never wraps)', () {
    testWidgets('overflowing tabs scroll horizontally on one row', (
      tester,
    ) async {
      final groups = [
        for (var i = 0; i < 10; i++) _wt('g$i', '/tmp/wt/branch-number-$i'),
      ];
      final c = _container(groups: groups, sessions: const []);
      // Narrow viewport so ten tabs cannot fit — they must scroll, not wrap.
      await _pump(tester, c, const GroupBar(), width: 260);

      final scrollable = find.descendant(
        of: find.byType(GroupBar),
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsOneWidget);

      final state = tester.state<ScrollableState>(scrollable);
      expect(state.position.axisDirection, AxisDirection.right);
      expect(
        state.position.maxScrollExtent,
        greaterThan(0),
        reason: 'the rail overflows into a scroll offset',
      );

      // A wrap would grow the bar past one row; it stays a single strip at the
      // macOS titlebar height (kTitleBarStripHeight).
      expect(
        tester.getSize(find.byType(GroupBar)).height,
        kTitleBarStripHeight,
      );
    });
  });

  group('GroupBar + menu (decision 8: recently closed boards)', () {
    testWidgets('lists a recently closed board and reopens it on tap', (
      tester,
    ) async {
      final closedBoard = _board('closed1', ['s1'], label: 'Old Board');
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/a')],
        sessions: [_session('s1')],
        recentlyClosed: [ClosedBoard(group: closedBoard, slot: 0)],
      );
      await _pump(tester, c, const GroupBar());

      await tester.tap(find.byTooltip('New board or reopen a closed one'));
      await tester.pumpAndSettle();

      expect(find.text('New board…'), findsOneWidget);
      expect(find.text('RECENTLY CLOSED BOARDS'), findsOneWidget);
      expect(find.textContaining('Old Board'), findsOneWidget);
      expect(find.textContaining('(1 live)'), findsOneWidget);

      await tester.tap(find.textContaining('Old Board'));
      await tester.pumpAndSettle();

      final state = c.read(groupsControllerProvider);
      expect(state.activeGroupId, 'closed1');
      expect(state.groups.any((g) => g.id == 'closed1'), isTrue);
      expect(state.recentlyClosed, isEmpty);
    });

    testWidgets('shows the empty state when nothing was closed', (
      tester,
    ) async {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/a')],
        sessions: const [],
      );
      await _pump(tester, c, const GroupBar());

      await tester.tap(find.byTooltip('New board or reopen a closed one'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing closed yet'), findsOneWidget);
    });

    testWidgets('New board… creates and activates a board', (tester) async {
      final c = _container(
        groups: [_wt('g1', '/tmp/wt/a')],
        sessions: const [],
      );
      await _pump(tester, c, const GroupBar());

      await tester.tap(find.byTooltip('New board or reopen a closed one'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New board…'));
      await tester.pumpAndSettle();

      final state = c.read(groupsControllerProvider);
      expect(state.groups.length, 2);
      expect(state.active.kind, GroupKind.board);
    });
  });
}
