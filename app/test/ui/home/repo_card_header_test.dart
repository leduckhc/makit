// The repo card's header is a right-aligned trailing cluster: open-PR count then
// the overflow menu, sharing a vertical line with the `+` on every worktree row
// below. The default branch used to sit here too; the star on the primary
// worktree row already says that, so it was the same fact twice.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';

RepoInfo _repo({bool withPr = false}) => RepoInfo(
  id: 'p1',
  name: 'makit',
  path: '/w',
  pinned: true,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    Worktree(
      id: '/a',
      path: '/a',
      branch: 'main',
      isPrimary: true,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: const [],
      pr: withPr
          ? const PullRequest(
              number: 7,
              url: 'x',
              state: 'OPEN',
              title: 't',
              isDraft: false,
            )
          : null,
    ),
  ],
);

Future<void> _pump(WidgetTester tester, {bool withPr = false}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        reposProvider.overrideWithValue(ReposState([_repo(withPr: withPr)])),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
        connectionProvider.overrideWithValue(MakitConnState()),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the overflow menu shares a column with the row + buttons', (
    tester,
  ) async {
    await _pump(tester);

    final dots = tester.getRect(find.byIcon(PhosphorIconsRegular.dotsThree));
    final plus = tester.getRect(
      find.byKey(const Key('newSessionInWorktree-/a')),
    );

    // Same vertical line. PopupMenuButton keeps IconButton's own inset unless it
    // is zero-padded *and* width-constrained, which silently pushed the glyph
    // ~9px left of the `+` column.
    expect(
      dots.center.dx,
      moreOrLessEquals(plus.center.dx, epsilon: 0.5),
      reason: 'the header menu must line up with the rows below it',
    );
  });

  testWidgets('the header no longer restates the default branch', (
    tester,
  ) async {
    await _pump(tester);

    // 'main' is the default branch AND the only worktree's branch. The worktree
    // row still names it; the header must not.
    expect(find.text('main'), findsOneWidget);
    expect(find.byIcon(PhosphorIconsLight.flag), findsNothing);
  });

  testWidgets('an open PR still counts in the header', (tester) async {
    await _pump(tester, withPr: true);

    expect(
      find.descendant(
        of: find.byKey(const Key('openPrCount')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });
}
