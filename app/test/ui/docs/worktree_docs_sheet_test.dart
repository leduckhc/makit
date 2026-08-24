// SPEC-docs-scoping-and-board-rework D1/D2 — the worktree docs sheet, the phone
// entry point that mirrors `showWorktreePortsSheet`. It lists ONLY the tapped
// worktree's docs (mtime-descending) and ends with one deliberate widening row,
// `All docs in <repo>`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/docs.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/docs/doc_row.dart';
import 'package:makit/ui/docs/worktree_docs_sheet.dart';

DocInfo _doc(
  String relPath, {
  String worktreePath = '/repo/a',
  int modifiedAt = 0,
  String title = 'Doc',
}) => DocInfo(
  key: '$worktreePath:$relPath',
  relPath: relPath,
  title: title,
  kind: DocKind.md,
  bytes: 10,
  modifiedAt: modifiedAt,
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
      Worktree(
        id: 'w2',
        path: '/repo/b',
        branch: 'main',
        isPrimary: true,
        insertions: 0,
        deletions: 0,
        filesChanged: 0,
        sessionIds: [],
      ),
    ],
  ),
]);

Widget _host(Widget child) => ProviderScope(
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  group('the body', () {
    testWidgets('header names the branch and lists exactly the given docs', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          WorktreeDocsSheetBody(
            branch: 'feat/a',
            docs: [
              _doc('a.md', title: 'Alpha'),
              _doc('b.md', title: 'Beta'),
            ],
            onOpenDoc: (_) {},
            nowMs: 0,
          ),
        ),
      );
      expect(find.text('Docs · feat/a'), findsOneWidget);
      expect(find.byType(DocRow), findsNWidgets(2));
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('tapping a row invokes onOpenDoc with that doc', (
      tester,
    ) async {
      DocInfo? opened;
      await tester.pumpWidget(
        _host(
          WorktreeDocsSheetBody(
            branch: 'feat/a',
            docs: [_doc('a.md', title: 'Alpha')],
            onOpenDoc: (d) => opened = d,
            nowMs: 0,
          ),
        ),
      );
      await tester.tap(find.text('Alpha'));
      expect(opened?.relPath, 'a.md');
    });

    testWidgets('the widening row appears only with a repo callback', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          WorktreeDocsSheetBody(
            branch: 'feat/a',
            docs: [_doc('a.md')],
            onOpenDoc: (_) {},
            nowMs: 0,
          ),
        ),
      );
      expect(find.text('All docs in makit'), findsNothing);

      var opened = 0;
      await tester.pumpWidget(
        _host(
          WorktreeDocsSheetBody(
            branch: 'feat/a',
            docs: [_doc('a.md')],
            onOpenDoc: (_) {},
            repoName: 'makit',
            onOpenDocsBoard: () => opened++,
            nowMs: 0,
          ),
        ),
      );
      await tester.tap(find.text('All docs in makit'));
      expect(opened, 1);
    });
  });

  group('showWorktreeDocsSheet is scoped to the tapped worktree', () {
    testWidgets(
      'the sheet lists only that worktree, and its row count equals the badge',
      (tester) async {
        // Two worktrees both own docs. A regression that opened the global list
        // would show three rows for a worktree whose badge reads two.
        final snapshot = DocsSnapshot(
          docs: [
            _doc('a1.md', worktreePath: '/repo/a', title: 'A one'),
            _doc('a2.md', worktreePath: '/repo/a', title: 'A two'),
            _doc('b1.md', worktreePath: '/repo/b', title: 'B one'),
          ],
          scannedAt: 0,
          scanOk: true,
        );
        final container = ProviderContainer(
          overrides: [
            docsProvider.overrideWithValue(snapshot),
            reposProvider.overrideWithValue(_repos()),
          ],
        );
        addTearDown(container.dispose);

        // The badge the glyph paints is the length of this scoped provider.
        final badgeCount = container
            .read(docsForWorktreeProvider('/repo/a'))
            .length;
        expect(badgeCount, 2);

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
                ],
              ),
            ),
          ),
        );

        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        // Non-vacuous: the row count equals the badge, and the OTHER worktree's
        // doc is absent, so a fall-back to the global list cannot pass.
        expect(find.byType(DocRow), findsNWidgets(badgeCount));
        expect(find.text('A one'), findsOneWidget);
        expect(find.text('A two'), findsOneWidget);
        expect(find.text('B one'), findsNothing);
      },
    );
  });
}
