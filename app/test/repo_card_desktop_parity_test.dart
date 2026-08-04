import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';
import 'package:makit/ui/home/new_session_sheet.dart';

/// The mobile home screen must speak the desktop sidebar's icon vocabulary —
/// DESIGN.md makes `prStateStyle`/`gitBranch` the shared branch glyph and
/// `folder` the repo glyph, so a concept cannot look like two different things
/// depending on which screen you opened.
Widget _host({required List<RepoInfo> repos, List<Session> sessions = const []}) {
  return ProviderScope(
    overrides: [
      reposProvider.overrideWithValue(ReposState(repos)),
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
    ],
    child: const MaterialApp(home: HomeScreen()),
  );
}

Worktree _wt({
  String path = '/tmp/demo',
  String branch = 'main',
  bool isPrimary = true,
  List<String> sessionIds = const [],
}) => Worktree(
  id: path,
  path: path,
  branch: branch,
  isPrimary: isPrimary,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: sessionIds,
);

RepoInfo _repo({List<Worktree>? worktrees}) => RepoInfo(
  id: 'p1',
  name: 'demo',
  path: '/tmp/demo',
  pinned: true,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: worktrees ?? [_wt()],
);

void main() {
  group('icon vocabulary matches the desktop sidebar', () {
    testWidgets('a repo header uses the plain folder glyph', (tester) async {
      await tester.pumpWidget(_host(repos: [_repo()]));
      await tester.pump();

      expect(find.byIcon(PhosphorIconsLight.folder), findsOneWidget);
      // `folderStar` means "starred/favourite" nowhere else in the app.
      expect(find.byIcon(PhosphorIconsLight.folderStar), findsNothing);
    });

    testWidgets('a worktree row uses the branch glyph, not treeStructure', (
      tester,
    ) async {
      await tester.pumpWidget(_host(repos: [_repo()]));
      await tester.pump();

      expect(find.byIcon(PhosphorIconsLight.gitBranch), findsWidgets);
      expect(find.byIcon(PhosphorIconsLight.treeStructure), findsNothing);
    });

    testWidgets('the repo overflow menu uses the same dots as desktop', (
      tester,
    ) async {
      await tester.pumpWidget(_host(repos: [_repo()]));
      await tester.pump();

      expect(find.byIcon(PhosphorIconsRegular.dotsThree), findsOneWidget);
      expect(
        find.byIcon(PhosphorIconsRegular.dotsThreeVertical),
        findsNothing,
      );
    });
  });

  group('starting a session on a specific worktree', () {
    testWidgets('every worktree row carries its own new-session button', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          repos: [
            _repo(
              worktrees: [
                _wt(path: '/tmp/demo', branch: 'main'),
                _wt(path: '/tmp/wt-a', branch: 'feat/a', isPrimary: false),
              ],
            ),
          ],
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('newSessionInWorktree-/tmp/demo')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('newSessionInWorktree-/tmp/wt-a')),
        findsOneWidget,
      );
    });
  });

  group('NewSessionSheet pre-targeting', () {
    testWidgets('an initial worktree path opens on that existing worktree', (
      tester,
    ) async {
      NewSessionChoice? choice;
      final worktrees = [
        _wt(path: '/tmp/demo', branch: 'main'),
        _wt(path: '/tmp/wt-a', branch: 'feat/a', isPrimary: false),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  choice = await showModalBottomSheet<NewSessionChoice>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => NewSessionSheet(
                      agents: const [],
                      branches: const ['main'],
                      worktrees: worktrees,
                      // The worktree row's `+` names the branch it sits on.
                      initialWorktreePath: '/tmp/wt-a',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      // Straight to Start: no re-picking the worktree the user came from.
      expect(choice, isNotNull);
      expect(choice!.source, WorktreeSource.existing);
      expect(choice!.worktreePath, '/tmp/wt-a');
    });

    testWidgets('without an initial path it still defaults to a new branch', (
      tester,
    ) async {
      NewSessionChoice? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  choice = await showModalBottomSheet<NewSessionChoice>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => NewSessionSheet(
                      agents: const [],
                      branches: const ['main'],
                      worktrees: [_wt()],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(choice!.source, WorktreeSource.newBranch);
    });
  });
}
