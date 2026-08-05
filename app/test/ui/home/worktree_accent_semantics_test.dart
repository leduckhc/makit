import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';

/// The accent bar encodes a worktree's state as a colour. Colour alone is
/// invisible to a screen reader (and WCAG 1.4.1 discourages it generally), so the
/// same state must be available as text in the semantics tree.
Widget _host(List<RepoInfo> repos, List<Session> sessions) => ProviderScope(
  overrides: [
    reposProvider.overrideWithValue(ReposState(repos)),
    sessionsProvider.overrideWithValue(SessionsState(sessions)),
  ],
  child: const MaterialApp(home: HomeScreen()),
);

RepoInfo _repo() => const RepoInfo(
  id: 'p1',
  name: 'demo',
  path: '/tmp/demo',
  pinned: true,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    Worktree(
      id: '/wt/a',
      path: '/wt/a',
      branch: 'feat/a',
      isPrimary: false,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: ['s1'],
    ),
  ],
);

Session _s(SessionStatus status) => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'work',
  status: status,
  policy: ApprovalPolicy.askOnRisky,
);

void main() {
  testWidgets(
    'a worktree awaiting the user says so in words, not just colour',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host([_repo()], [_s(SessionStatus.awaitingApproval)]),
      );
      await tester.pump();

      expect(
        find.bySemanticsLabel(RegExp('waiting for you', caseSensitive: false)),
        findsWidgets,
      );
      handle.dispose();
    },
  );

  testWidgets('a quiet worktree makes no state claim', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host([_repo()], [_s(SessionStatus.idle)]));
    await tester.pump();

    expect(
      find.bySemanticsLabel(RegExp('waiting for you', caseSensitive: false)),
      findsNothing,
    );
    handle.dispose();
  });
}
