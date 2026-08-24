// SPEC-docs-scoping-and-board-rework D1 — the worktree row's docs glyph opens a
// SCOPED sheet, not the host-wide board. A badge that reads N must produce a
// list of N, so tapping the glyph must NOT `context.go(kRouteDocs)`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/app/routes.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/docs.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/docs/doc_glyph.dart';
import 'package:makit/ui/docs/docs_screen.dart';
import 'package:makit/ui/home/worktree_row.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

const _worktree = Worktree(
  id: '/tmp/feature',
  path: '/tmp/feature',
  branch: 'add-login',
  isPrimary: false,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: [],
);

const _repo = RepoInfo(
  id: 'p1',
  name: 'demo',
  path: '/tmp/demo',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [_worktree],
);

DocsSnapshot _snap() => const DocsSnapshot(
  docs: [
    DocInfo(
      key: '/tmp/feature:docs/a.md',
      relPath: 'docs/a.md',
      title: 'Alpha doc',
      kind: DocKind.md,
      bytes: 10,
      modifiedAt: 0,
      worktreePath: '/tmp/feature',
    ),
  ],
  scannedAt: 0,
  scanOk: true,
);

Future<void> _pump(WidgetTester tester) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: WorktreeRow(repo: _repo, worktree: _worktree, sessions: []),
        ),
      ),
      // The board IS reachable — if the glyph regressed to `context.go`, this
      // route would build a DocsScreen, so `findsNothing` below is meaningful.
      GoRoute(path: kRouteDocs, builder: (_, _) => const DocsScreen()),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      docsWatchProvider.overrideWithValue(DocsWatch((_) {})),
      docsProvider.overrideWithValue(_snap()),
      reposProvider.overrideWithValue(ReposState(const [_repo])),
      sessionsProvider.overrideWithValue(SessionsState(const [])),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the glyph opens the scoped sheet, never the board', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(DocsGlyph), findsOneWidget);

    await tester.tap(find.byType(DocsGlyph));
    await tester.pumpAndSettle();

    // The sheet names the branch, so the door is scoped to this worktree.
    expect(find.text('Docs · add-login'), findsOneWidget);
    expect(find.text('Alpha doc'), findsOneWidget);
    // The host-wide board did NOT open.
    expect(find.byType(DocsScreen), findsNothing);
  });
}
