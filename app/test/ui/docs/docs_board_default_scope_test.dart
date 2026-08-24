// SPEC-docs-scoping-and-board-rework D4 — unscoped with more than one repo,
// only the repo owning the newest doc stays expanded; the others fold to a
// counted header, the `_systemExpanded=false` folding precedent from Ports.
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

Future<void> _pump(WidgetTester tester) async {
  // A tall surface so the lazy ListView builds every group header and row; the
  // folding assertions then read true absence, not merely "below the fold".
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // alpha owns the newest doc (mtime 105); beta's docs are older (10, 11) so
  // they never enter the 5-newest Recent group either.
  final snapshot = DocsSnapshot(
    docs: [
      for (var i = 0; i < 6; i++)
        _doc(
          'a$i.md',
          worktreePath: '/alpha/wt',
          modifiedAt: 100 + i,
          title: 'A$i',
        ),
      _doc('b0.md', worktreePath: '/beta/wt', modifiedAt: 10, title: 'B0'),
      _doc('b1.md', worktreePath: '/beta/wt', modifiedAt: 11, title: 'B1'),
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
      child: const MaterialApp(home: DocsScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('only the repo owning the newest doc is expanded', (
    tester,
  ) async {
    await _pump(tester);
    // Both repo headers are present.
    expect(find.text('ALPHA'), findsOneWidget);
    expect(find.text('BETA'), findsOneWidget);
    // alpha is expanded: at least one of its docs shows in its group.
    expect(
      find.byKey(const ValueKey('docs-screen-row-/alpha/wt:a5.md')),
      findsOneWidget,
    );
    // beta is folded: its docs are not built, and are not in Recent either
    // (they are older than alpha's newest five).
    expect(find.text('B0'), findsNothing);
    expect(find.text('B1'), findsNothing);
  });

  testWidgets('tapping the folded header expands it', (tester) async {
    await _pump(tester);
    expect(find.text('B0'), findsNothing);
    await tester.tap(find.text('BETA'));
    await tester.pump();
    expect(find.text('B0'), findsOneWidget);
    expect(find.text('B1'), findsOneWidget);
  });
}
