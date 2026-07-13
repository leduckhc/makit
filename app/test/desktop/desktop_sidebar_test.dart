import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_sidebar.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

RepoInfo _repo(
  String id,
  String name, {
  String? currentBranch,
  String? defaultBranch,
  List<Worktree> worktrees = const [],
}) => RepoInfo(
  id: id,
  name: name,
  path: '/tmp/$id',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: defaultBranch ?? 'main',
  currentBranch: currentBranch ?? 'main',
  worktrees: worktrees,
);

Worktree _worktree(
  String id, {
  String? branch,
  bool isPrimary = false,
  int insertions = 0,
  int deletions = 0,
  int filesChanged = 0,
  List<String> sessionIds = const [],
  PullRequest? pr,
}) => Worktree(
  id: id,
  path: '/tmp/wt/$id',
  branch: branch,
  isPrimary: isPrimary,
  insertions: insertions,
  deletions: deletions,
  filesChanged: filesChanged,
  sessionIds: sessionIds,
  pr: pr,
);

Session _session(
  String id,
  String projectId,
  String title,
  String agent, {
  bool pending = false,
}) => Session(
  id: id,
  projectId: projectId,
  agent: agent,
  title: title,
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  pending: pending,
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required List<RepoInfo> repos,
  required List<Session> sessions,
}) async {
  final container = ProviderContainer(
    overrides: [
      reposProvider.overrideWithValue(ReposState(repos)),
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, child: DesktopSidebar())),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('sidebar groups sessions by repo → worktree', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-main', branch: 'main', isPrimary: true),
            _worktree(
              'wt-feat',
              branch: 'feat/login',
              insertions: 12,
              deletions: 3,
              sessionIds: ['s1'],
            ),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
    );

    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('feat/login'), findsOneWidget);
    expect(find.text('Fix login bug'), findsOneWidget);
    // Only the worktree diff chip now (the repo-rollup aggregate was removed).
    expect(find.text('+12'), findsOneWidget);
    expect(find.text('−3'), findsOneWidget);
  });

  testWidgets('tapping a session selects it', (tester) async {
    final container = await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree(
              'wt-main',
              branch: 'main',
              isPrimary: true,
              sessionIds: ['s1'],
            ),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'Fix login bug', 'codex')],
    );

    expect(container.read(selectedSessionProvider), isNull);

    await tester.tap(find.text('Fix login bug'));
    await tester.pump();

    expect(container.read(selectedSessionProvider), 's1');
  });

  testWidgets('drafts land in a DRAFTS section', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [_worktree('wt-main', branch: 'main', isPrimary: true)],
        ),
      ],
      sessions: [_session('s1', 'p1', '', 'pi', pending: true)],
    );

    expect(find.text('DRAFTS'), findsOneWidget);
    expect(find.text('new session'), findsOneWidget);
    expect(find.text('draft'), findsOneWidget);
  });

  testWidgets('open PR renders a PR pill on its worktree row', (tester) async {
    await _pump(
      tester,
      repos: [
        _repo(
          'p1',
          'alpha',
          worktrees: [
            _worktree('wt-main', branch: 'main', isPrimary: true),
            _worktree(
              'wt-feat',
              branch: 'feat/x',
              insertions: 1,
              sessionIds: ['s1'],
              pr: const PullRequest(
                number: 42,
                url: '',
                state: 'OPEN',
                title: 'x',
                isDraft: false,
              ),
            ),
          ],
        ),
      ],
      sessions: [_session('s1', 'p1', 'work', 'pi')],
    );

    expect(find.text('PR #42'), findsOneWidget);
    expect(find.text('1 open PR'), findsOneWidget);
  });

  testWidgets('empty state prompts to start a session', (tester) async {
    await _pump(tester, repos: const [], sessions: const []);
    expect(find.textContaining('No repos yet'), findsOneWidget);
  });
}
