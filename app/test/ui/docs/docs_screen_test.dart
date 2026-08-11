import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/docs/doc_row.dart';
import 'package:makit/ui/docs/docs_screen.dart';

DocInfo _doc(
  String relPath, {
  String worktreePath = '/A/feat',
  DocKind kind = DocKind.md,
  int modifiedAt = 0,
  bool? changed,
  String title = 'Doc title',
}) => DocInfo(
  key: '$worktreePath:$relPath',
  relPath: relPath,
  title: title,
  kind: kind,
  bytes: 10,
  modifiedAt: modifiedAt,
  worktreePath: worktreePath,
  changed: changed,
);

Worktree _wt(String path, String branch) => Worktree(
  id: path,
  path: path,
  branch: branch,
  isPrimary: false,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: const [],
);

final _repos = ReposState([
  RepoInfo(
    id: 'A',
    name: 'makit',
    path: '/A',
    pinned: false,
    lastActivityAt: 0,
    isGitRepo: true,
    defaultBranch: 'main',
    currentBranch: 'main',
    worktrees: [_wt('/A/feat', 'feat/serving-html')],
  ),
]);

DocsSnapshot _snap(List<DocInfo> docs) =>
    DocsSnapshot(docs: docs, scannedAt: 0, scanOk: true);

Future<DocsWatch> _pump(WidgetTester tester, DocsSnapshot? snapshot) async {
  final calls = <bool>[];
  final watch = DocsWatch(calls.add);
  final container = ProviderContainer(
    overrides: [
      docsWatchProvider.overrideWithValue(watch),
      docsProvider.overrideWithValue(snapshot),
      reposProvider.overrideWithValue(_repos),
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
  return watch;
}

void main() {
  testWidgets('holds the docs.watch while mounted, releases on dispose', (
    tester,
  ) async {
    final watch = await _pump(tester, _snap(const []));
    expect(watch.watcherCount, 1);
    // Replace the screen: dispose must release the watch (screen popped).
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(watch.watcherCount, 0);
  });

  testWidgets('empty state when the scan succeeded with zero docs', (
    tester,
  ) async {
    await _pump(tester, _snap(const []));
    expect(find.byKey(kDocsEmptyState), findsOneWidget);
  });

  testWidgets('groups docs under repo → worktree with a branch chip', (
    tester,
  ) async {
    await _pump(tester, _snap([_doc('docs/a.md', title: 'Alpha')]));
    expect(find.text('MAKIT'), findsOneWidget);
    expect(find.text('feat/serving-html'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('filter row shows counts and Specs filters to docs/', (
    tester,
  ) async {
    await _pump(
      tester,
      _snap([
        _doc('mockups/x.html', kind: DocKind.html, title: 'Board'),
        _doc('docs/s.md', title: 'Spec'),
      ]),
    );
    // Both visible under All.
    expect(find.byType(DocRow), findsNWidgets(2));
    // Tap the Specs chip.
    await tester.tap(find.text('Specs 1'));
    await tester.pump();
    expect(find.byType(DocRow), findsOneWidget);
    expect(find.text('Spec'), findsOneWidget);
    expect(find.text('Board'), findsNothing);
  });

  testWidgets('search field filters by title and path', (tester) async {
    await _pump(
      tester,
      _snap([
        _doc('docs/ports.md', title: 'Ports forward'),
        _doc('docs/other.md', title: 'Something else'),
      ]),
    );
    await tester.enterText(find.byType(TextField), 'ports');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Ports forward'), findsOneWidget);
    expect(find.text('Something else'), findsNothing);
  });

  testWidgets('shows a spinner before the first snapshot', (tester) async {
    await _pump(tester, null);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  // The global screen aggregates docs across every repo, so it must not build a
  // DocRow per doc — the popover was made lazy for the same reason. An eager
  // ListView(children: [...]) builds all N rows; ListView.builder builds only
  // the ones the viewport shows.
  testWidgets('builds only the visible rows, not one per doc', (tester) async {
    final docs = [
      for (var i = 0; i < 200; i++)
        _doc('docs/note-$i.md', title: 'Note $i', modifiedAt: 200 - i),
    ];
    await _pump(tester, _snap(docs));
    final built = find.byType(DocRow).evaluate().length;
    expect(built, lessThan(40), reason: 'the list must be lazy, not 200 rows');
    expect(built, greaterThan(0));
  });
}
