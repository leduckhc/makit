// Worktree lifecycle from the phone (parity with the desktop sidebar's row menu
// and its "+ New worktree" button): create a worktree without starting a
// session, rename a branch, delete a worktree — with the same guards desktop
// applies.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/repo_card.dart';
import 'package:makit/ui/home/worktree_actions.dart';
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

/// Records the worktree mutations the UI asks for.
class _FakeStore extends StoreController {
  _FakeStore(super.ref);

  final List<String?> createdFrom = [];
  final List<(String, String)> renamed = [];
  final List<String> removed = [];
  int spawnCount = 0;

  @override
  Future<({String path, String? branch})> createWorktree(
    String projectId, {
    String? baseBranch,
    String? branchName,
  }) async {
    createdFrom.add(baseBranch);
    return (path: '/tmp/demo/.wt/fresh', branch: 'fresh-branch');
  }

  @override
  Future<void> renameBranch(
    String projectId,
    String worktreePath,
    String newName,
  ) async => renamed.add((worktreePath, newName));

  @override
  Future<void> removeWorktree(String projectId, String worktreePath) async =>
      removed.add(worktreePath);

  @override
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    spawnCount++;
    return 's-new';
  }

  @override
  Future<List<AgentDescriptor>> fetchAgents() async => const [];

  @override
  Future<List<OpenPr>> listOpenPrs(String projectId) async => const [];
}

Worktree _wt({
  String branch = 'add-login',
  bool isPrimary = false,
  PullRequest? pr,
  List<String> sessionIds = const [],
}) => Worktree(
  id: '/tmp/demo/.wt/$branch',
  path: '/tmp/demo/.wt/$branch',
  branch: branch,
  isPrimary: isPrimary,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: sessionIds,
  pr: pr,
);

Worktree _detached() => const Worktree(
  id: '/tmp/demo/.wt/detached',
  path: '/tmp/demo/.wt/detached',
  branch: null,
  isPrimary: false,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: [],
);

PullRequest _openPr() => const PullRequest(
  number: 42,
  url: 'https://github.com/o/r/pull/42',
  state: 'OPEN',
  title: 'Add the login screen',
  isDraft: false,
);

RepoInfo _repo(List<Worktree> worktrees) => RepoInfo(
  id: 'p1',
  name: 'demo',
  path: '/tmp/demo',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: worktrees,
);

/// Pumps [child] with a fake store, returning it so tests can assert calls.
Future<_FakeStore> _pump(WidgetTester tester, Widget child) async {
  late _FakeStore store;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            Scaffold(body: ListView(children: [child])),
      ),
      GoRoute(path: '/session/:id', builder: (_, _) => const SizedBox()),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      storeControllerProvider.overrideWith((ref) {
        store = _FakeStore(ref);
        return store;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(storeControllerProvider.notifier);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

ListTile _tile(WidgetTester tester, String label) =>
    tester.widget<ListTile>(find.widgetWithText(ListTile, label));

void main() {
  group('guards', () {
    test('a feature branch can be renamed and deleted', () {
      final w = _wt();
      expect(canRenameWorktree(w), isTrue);
      expect(canDeleteWorktree(w), isTrue);
    });

    test('the primary checkout can be neither', () {
      final w = _wt(branch: 'main', isPrimary: true);
      expect(canRenameWorktree(w), isFalse);
      expect(canDeleteWorktree(w), isFalse);
    });

    test('a detached worktree cannot be renamed', () {
      expect(canRenameWorktree(_detached()), isFalse);
      expect(canDeleteWorktree(_detached()), isTrue);
    });

    test('a branch heading an open PR cannot be renamed', () {
      final w = _wt(pr: _openPr());
      expect(canRenameWorktree(w), isFalse);
      expect(canDeleteWorktree(w), isTrue);
    });
  });

  group('worktree actions sheet', () {
    testWidgets('long-pressing the row opens it', (tester) async {
      final repo = _repo([_wt()]);
      await _pump(
        tester,
        WorktreeRow(
          repo: repo,
          worktree: repo.worktrees.first,
          sessions: const [],
        ),
      );

      await tester.longPress(find.text('add-login'));
      await tester.pumpAndSettle();

      expect(find.text('Rename branch'), findsOneWidget);
      expect(find.text('Delete worktree'), findsOneWidget);
    });

    testWidgets('disables both actions on the primary checkout', (
      tester,
    ) async {
      final repo = _repo([_wt(branch: 'main', isPrimary: true)]);
      await _pump(
        tester,
        WorktreeRow(
          repo: repo,
          worktree: repo.worktrees.first,
          sessions: const [],
        ),
      );

      await tester.longPress(find.text('main'));
      await tester.pumpAndSettle();

      expect(_tile(tester, 'Rename branch').enabled, isFalse);
      expect(_tile(tester, 'Delete worktree').enabled, isFalse);
    });

    testWidgets('renames the branch to the typed name', (tester) async {
      final repo = _repo([_wt()]);
      final store = await _pump(
        tester,
        WorktreeRow(
          repo: repo,
          worktree: repo.worktrees.first,
          sessions: const [],
        ),
      );

      await tester.longPress(find.text('add-login'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename branch'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'login-screen');
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await tester.pumpAndSettle();

      expect(store.renamed, [('/tmp/demo/.wt/add-login', 'login-screen')]);
    });

    testWidgets('deletes only after the confirmation', (tester) async {
      final repo = _repo([_wt()]);
      final store = await _pump(
        tester,
        WorktreeRow(
          repo: repo,
          worktree: repo.worktrees.first,
          sessions: const [],
        ),
      );

      await tester.longPress(find.text('add-login'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete worktree'));
      await tester.pumpAndSettle();
      expect(store.removed, isEmpty, reason: 'deleted without confirming');

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(store.removed, ['/tmp/demo/.wt/add-login']);
    });
  });

  group('new worktree', () {
    testWidgets('the card footer offers it', (tester) async {
      final repo = _repo([_wt(branch: 'main', isPrimary: true)]);
      await _pump(tester, RepoCard(repo: repo, sessions: const []));

      // The footer, not the overflow menu: every worktree row has its own `+`
      // for sessions, so the card-level action is adding a worktree.
      expect(find.byKey(const Key('newWorktreeFooter')), findsOneWidget);
      await tester.tap(find.byTooltip('Repo actions'));
      await tester.pumpAndSettle();
      expect(
        find.text('New worktree'),
        findsOneWidget,
        reason: 'the menu must not repeat what the footer already shows',
      );
    });

    testWidgets('creates off the chosen base branch without a session', (
      tester,
    ) async {
      final repo = _repo([_wt(branch: 'main', isPrimary: true), _wt()]);
      final store = await _pump(
        tester,
        RepoCard(repo: repo, sessions: const []),
      );

      await tester.tap(find.byKey(const Key('newWorktreeFooter')));
      await tester.pumpAndSettle();

      // The sheet lists the repo's branches as fork points.
      await tester.tap(find.widgetWithText(ListTile, 'add-login'));
      await tester.pumpAndSettle();

      expect(store.createdFrom, ['add-login']);
      expect(
        store.spawnCount,
        0,
        reason: 'a new worktree must not start a session',
      );
    });
  });
}
