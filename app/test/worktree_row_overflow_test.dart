import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';

/// The worktree row packs a lot into one line: caret, branch glyph, branch name,
/// current-branch star, `default` tag, diff chip, PR pill — and now a
/// new-session button. On the narrowest phone that has to fit without a
/// RenderFlex overflow.
Widget _host(List<RepoInfo> repos, List<Session> sessions) => ProviderScope(
  overrides: [
    reposProvider.overrideWithValue(ReposState(repos)),
    sessionsProvider.overrideWithValue(SessionsState(sessions)),
  ],
  child: const MaterialApp(home: HomeScreen()),
);

void main() {
  testWidgets('a maximally busy worktree row fits a 320pt-wide phone', (
    tester,
  ) async {
    // iPhone SE (1st gen) logical width — the narrowest target still supported.
    tester.view.physicalSize = const Size(320 * 3, 568 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    const repo = RepoInfo(
      id: 'p1',
      name: 'a-repo-with-a-fairly-long-name',
      path: '/tmp/demo',
      pinned: true,
      lastActivityAt: 0,
      isGitRepo: true,
      defaultBranch: 'main',
      currentBranch: 'main',
      worktrees: [
        // Primary, current AND default, dirty, with an open PR: every optional
        // element in the row present at once.
        Worktree(
          id: '/tmp/demo',
          path: '/tmp/demo',
          branch: 'main',
          isPrimary: true,
          insertions: 1234,
          deletions: 5678,
          filesChanged: 42,
          sessionIds: ['s1'],
          pr: PullRequest(
            number: 4321,
            url: 'https://example.com/pr/4321',
            state: 'OPEN',
            title: 'Big change',
            isDraft: false,
          ),
        ),
        // A long branch name must ellipsize rather than push the row wider.
        Worktree(
          id: '/tmp/wt',
          path: '/tmp/wt',
          branch: 'feature/some-extremely-long-branch-name-that-will-not-fit',
          isPrimary: false,
          insertions: 99,
          deletions: 99,
          filesChanged: 9,
          sessionIds: [],
        ),
      ],
    );

    await tester.pumpWidget(
      _host(
        [repo],
        [
          Session(
            id: 's1',
            projectId: 'p1',
            agent: 'pi',
            title: 'a session with a long enough title to crowd the row',
            status: SessionStatus.awaitingApproval,
            policy: ApprovalPolicy.askOnRisky,
          ),
        ],
      ),
    );
    await tester.pump();

    // Any RenderFlex overflow is reported through the error hook.
    expect(tester.takeException(), isNull);
    // The per-worktree affordance survives the squeeze on both rows.
    expect(
      find.byKey(const Key('newSessionInWorktree-/tmp/demo')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('newSessionInWorktree-/tmp/wt')),
      findsOneWidget,
    );
  });
}
