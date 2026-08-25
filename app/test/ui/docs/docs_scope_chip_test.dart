// SPEC-docs-scoping-and-board-rework D2/D3 — widening is a deliberate act, and
// the board takes its scope from the route exactly like Ports. `All docs in
// <repo>` opens the board with `?repo=<id>`; `This repo` is pre-selected when
// scoped and the chip is absent when not.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/app/routes.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/docs/docs_screen.dart';
import 'package:makit/ui/docs/worktree_docs_sheet.dart';

DocInfo _doc(String relPath, {String worktreePath = '/repo/a'}) => DocInfo(
  key: '$worktreePath:$relPath',
  relPath: relPath,
  title: relPath,
  kind: DocKind.md,
  bytes: 10,
  modifiedAt: 0,
  worktreePath: worktreePath,
);

ReposState _repos() => ReposState([
  const RepoInfo(
    id: 'r1',
    name: 'makit',
    path: '/repo',
    pinned: false,
    lastActivityAt: 0,
    isGitRepo: true,
    defaultBranch: 'main',
    currentBranch: 'main',
    worktrees: [
      Worktree(
        id: 'w1',
        path: '/repo/a',
        branch: 'feat/a',
        isPrimary: false,
        insertions: 0,
        deletions: 0,
        filesChanged: 0,
        sessionIds: [],
      ),
    ],
  ),
]);

DocsSnapshot _snap(List<DocInfo> docs) =>
    DocsSnapshot(docs: docs, scannedAt: 0, scanOk: true);

ProviderContainer _container(DocsSnapshot snapshot) => ProviderContainer(
  overrides: [
    docsWatchProvider.overrideWithValue(DocsWatch((_) {})),
    docsProvider.overrideWithValue(snapshot),
    reposProvider.overrideWithValue(_repos()),
    sessionsProvider.overrideWithValue(SessionsState(const [])),
  ],
);

Future<void> _pumpScreen(WidgetTester tester, {String? repoId}) async {
  final container = _container(_snap([_doc('a.md')]));
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
  testWidgets('"All docs in <repo>" opens the board with ?repo=<id>', (
    tester,
  ) async {
    final container = _container(_snap([_doc('a.md')]));
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (ctx, _) => Scaffold(
                  body: ElevatedButton(
                    onPressed: () => showWorktreeDocsSheet(
                      ctx,
                      worktreePath: '/repo/a',
                      branch: 'feat/a',
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
              GoRoute(
                path: kRouteDocs,
                builder: (_, s) =>
                    DocsScreen(repoId: s.uri.queryParameters['repo']),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All docs in makit'));
    await tester.pumpAndSettle();

    // The board opened, scoped to the repo the worktree belongs to.
    final screen = tester.widget<DocsScreen>(find.byType(DocsScreen));
    expect(screen.repoId, 'r1');
    // The sheet popped first: its header is gone.
    expect(find.text('Docs · feat/a'), findsNothing);
  });

  testWidgets('scoped: no "This repo" chip; "All" is the default (D9)', (
    tester,
  ) async {
    // D9 dropped the `This repo` chip: the board is always one project, so a
    // scope chip could only ever be on. `All` now means "all docs in this
    // project".
    await _pumpScreen(tester, repoId: 'r1');
    expect(find.widgetWithText(ChoiceChip, 'This repo'), findsNothing);
    final all = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'All 1'),
    );
    expect(all.selected, isTrue);
  });

  testWidgets('unscoped: no "This repo" chip; "All" is the default (D9)', (
    tester,
  ) async {
    await _pumpScreen(tester);
    expect(find.widgetWithText(ChoiceChip, 'This repo'), findsNothing);
    final all = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'All 1'),
    );
    expect(all.selected, isTrue);
  });
}
