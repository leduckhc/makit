// SPEC-docs-scoping-and-board-rework D8 — the board shows exactly one project.
// Unscoped, the effective repo is the one owning the newest doc. Another
// project is never rendered, not even collapsed, and its docs never leak into
// the Recent group. Switching project is an explicit act through an app-bar
// menu; the choice is view state.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/store/docs.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/docs/docs_screen.dart';

DocInfo _doc(
  String relPath, {
  required String worktreePath,
  required int modifiedAt,
  required String title,
}) => DocInfo(
  key: '$worktreePath:$relPath',
  relPath: relPath,
  title: title,
  kind: DocKind.md,
  bytes: 10,
  modifiedAt: modifiedAt,
  worktreePath: worktreePath,
);

RepoInfo _repo(String id, String name, String wtPath) => RepoInfo(
  id: id,
  name: name,
  path: '/$id',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    Worktree(
      id: wtPath,
      path: wtPath,
      branch: 'main',
      isPrimary: true,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: const [],
    ),
  ],
);

Future<void> _pump(WidgetTester tester, {String? repoId}) async {
  // A tall surface so the lazy ListView builds every group header and row; the
  // absence assertions then read true absence, not merely "below the fold".
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // alpha owns the single newest doc (mtime 1000), so it is the effective
  // project. beta holds a doc (mtime 999) that is NEWER than alpha's older doc
  // (mtime 1) — a naive recentDocs(allDocs) would pull it into the top five, so
  // its absence proves Recent is scoped to the active project, not merely
  // "not interleaved".
  final snapshot = DocsSnapshot(
    docs: [
      _doc(
        'a_new.md',
        worktreePath: '/alpha/wt',
        modifiedAt: 1000,
        title: 'ANew',
      ),
      _doc('a_old.md', worktreePath: '/alpha/wt', modifiedAt: 1, title: 'AOld'),
      _doc(
        'b_mid.md',
        worktreePath: '/beta/wt',
        modifiedAt: 999,
        title: 'BMid',
      ),
    ],
    scannedAt: 0,
    scanOk: true,
  );
  final container = ProviderContainer(
    overrides: [
      docsWatchProvider.overrideWithValue(DocsWatch((_) {})),
      docsProvider.overrideWithValue(snapshot),
      reposProvider.overrideWithValue(
        ReposState([
          _repo('alpha', 'alpha', '/alpha/wt'),
          _repo('beta', 'beta', '/beta/wt'),
        ]),
      ),
      sessionsProvider.overrideWithValue(SessionsState(const [])),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: DocsScreen(repoId: repoId)),
    ),
  );
  await tester.pump();
}

void main() {
  // The ONLY navigation to this board in the whole app is
  // `worktree_docs_sheet.dart:57`, which always passes `?repo=`. So the scoped
  // case below is the one that ships; an unscoped board is reachable from tests
  // alone. Without these two cases the project switcher would be dead code on
  // the phone, which this repo treats as a defect class, not a nicety.
  testWidgets('the switcher is reachable on a route-scoped board', (
    tester,
  ) async {
    await _pump(tester, repoId: 'alpha');
    expect(find.text('AOld'), findsWidgets);
    expect(find.text('BMid'), findsNothing);
    // Non-vacuous: this fails while `_projectMenu` returns SizedBox.shrink()
    // for any scoped board, which is exactly the shipped path.
    expect(
      find.text('alpha'),
      findsOneWidget,
      reason: 'a scoped board must still offer the project switcher',
    );
  });

  testWidgets('switching away from the route scope swaps the list', (
    tester,
  ) async {
    await _pump(tester, repoId: 'alpha');
    await tester.tap(find.text('alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('beta').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // The user's pick must beat `?repo=`, and the invariant must hold after it:
    // exactly one project on screen, now the other one.
    expect(find.text('BMid'), findsWidgets);
    expect(find.text('ANew'), findsNothing);
    expect(find.text('AOld'), findsNothing);
    expect(find.text('ALPHA'), findsNothing);
  });

  testWidgets('the board never renders a second project', (tester) async {
    await _pump(tester);
    // The active project's docs are present.
    expect(find.text('ANew'), findsWidgets);
    expect(find.text('AOld'), findsWidgets);
    // The other project is never rendered: not its group header, and not its
    // docs — not even folded, and not leaked into Recent despite mtime 999.
    expect(find.text('BETA'), findsNothing);
    expect(find.text('BMid'), findsNothing);
  });

  testWidgets(
    'switching project through the app-bar menu swaps the whole list',
    (tester) async {
      await _pump(tester);
      // The menu names the current project.
      expect(find.text('alpha'), findsOneWidget);
      // Open the menu and pick the other project.
      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('beta').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // The whole list swapped: the first project's docs are absent, the second
      // project's docs are present.
      expect(find.text('ANew'), findsNothing);
      expect(find.text('AOld'), findsNothing);
      expect(find.text('ALPHA'), findsNothing);
      expect(find.text('BMid'), findsWidgets);
    },
  );
}
