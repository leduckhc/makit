// Mobile repo card structure, matching the desktop sidebar's repo group:
// tapping the header collapses the card's contents, and past five worktrees the
// tail hides behind a "Show N more" toggle.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';
import 'package:makit/ui/home/repo_card.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

Worktree wt(
  String branch, {
  bool isPrimary = false,
  int insertions = 0,
  List<String> sessionIds = const [],
}) => Worktree(
  id: '/tmp/$branch',
  path: '/tmp/$branch',
  branch: branch,
  isPrimary: isPrimary,
  insertions: insertions,
  deletions: 0,
  filesChanged: insertions > 0 ? 1 : 0,
  sessionIds: sessionIds,
);

RepoInfo repoWith(List<Worktree> worktrees) => RepoInfo(
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

Future<void> pumpCard(WidgetTester tester, List<Worktree> worktrees) async {
  final repo = repoWith(worktrees);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: ListView(
            children: [RepoCard(repo: repo, sessions: const [])],
          ),
        ),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
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

/// Six worktrees — one over the collapse threshold. `sortWorktreesForDisplay`
/// keeps the primary first and is stable for the rest (all equally quiet), so
/// `tail` is the one that lands past the cut.
List<Worktree> sixWorktrees() => [
  wt('trunk', isPrimary: true),
  wt('one'),
  wt('two'),
  wt('three'),
  wt('four'),
  wt('tail'),
];

void main() {
  group('repo card collapse', () {
    testWidgets('starts expanded and hides its worktrees when tapped', (
      tester,
    ) async {
      await pumpCard(tester, [wt('trunk', isPrimary: true), wt('feature')]);

      expect(find.text('feature'), findsOneWidget);

      await tester.tap(find.text('demo'));
      await tester.pumpAndSettle();

      expect(find.text('feature'), findsNothing);
      // The repo itself stays on screen — collapsing hides contents, not the card.
      expect(find.text('demo'), findsOneWidget);
    });

    testWidgets('expands again on a second tap', (tester) async {
      await pumpCard(tester, [wt('trunk', isPrimary: true), wt('feature')]);

      await tester.tap(find.text('demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('demo'));
      await tester.pumpAndSettle();

      expect(find.text('feature'), findsOneWidget);
    });
  });

  group('show more worktrees', () {
    testWidgets('caps the list at five and hides the rest behind a toggle', (
      tester,
    ) async {
      await pumpCard(tester, sixWorktrees());

      expect(find.text('trunk'), findsOneWidget);
      expect(find.text('four'), findsOneWidget);
      expect(find.text('tail'), findsNothing);

      await tester.tap(find.text('Show 1 more'));
      await tester.pumpAndSettle();

      expect(find.text('tail'), findsOneWidget);

      await tester.tap(find.text('Show less'));
      await tester.pumpAndSettle();

      expect(find.text('tail'), findsNothing);
    });

    testWidgets('offers no toggle at or below five worktrees', (tester) async {
      await pumpCard(tester, [
        wt('trunk', isPrimary: true),
        wt('one'),
        wt('two'),
        wt('three'),
        wt('four'),
      ]);

      expect(find.textContaining('Show'), findsNothing);
      expect(find.text('four'), findsOneWidget);
    });

    testWidgets('the toggle goes away with the collapsed card', (tester) async {
      await pumpCard(tester, sixWorktrees());

      await tester.tap(find.text('demo'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Show'), findsNothing);
    });
  });

  testWidgets('worktree fold state follows the worktree, not the slot', (
    tester,
  ) async {
    // sortWorktreesForDisplay reorders on activity, so a folded worktree can
    // change index while the user looks at it. Same failure mode the repo cards
    // had: without a per-worktree key the fold belongs to the position.
    final quiet = wt('quiet', sessionIds: const ['s2']);
    final busy = wt('busy', insertions: 20, sessionIds: const ['s1']);
    final sessions = [
      Session(
        id: 's1',
        projectId: 'p1',
        agent: 'pi',
        title: 'busy session',
        status: SessionStatus.idle,
        policy: ApprovalPolicy.askOnRisky,
      ),
      Session(
        id: 's2',
        projectId: 'p1',
        agent: 'pi',
        title: 'quiet session',
        status: SessionStatus.idle,
        policy: ApprovalPolicy.askOnRisky,
      ),
    ];

    Future<void> pumpOrder(List<Worktree> worktrees) async {
      final repo = repoWith(worktrees);
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [RepoCard(repo: repo, sessions: sessions)],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpOrder([busy, quiet]);
    // Fold `quiet` by tapping its row.
    await tester.tap(find.text('quiet'));
    await tester.pumpAndSettle();
    expect(find.text('quiet session'), findsNothing);
    expect(find.text('busy session'), findsOneWidget);

    // `quiet` gains changes and sorts above `busy`.
    await pumpOrder([
      wt('quiet', insertions: 99, sessionIds: const ['s2']),
      busy,
    ]);

    // It is still the folded one; `busy` did not inherit the fold.
    expect(find.text('quiet session'), findsNothing);
    expect(find.text('busy session'), findsOneWidget);
  });

  testWidgets('collapse state follows the repo when the list reorders', (
    tester,
  ) async {
    // Repos are ordered by activity, so a card can change list position while
    // the user is looking at it. Without a per-repo key the collapsed state
    // belongs to the slot, and an unrelated repo would appear collapsed.
    final alpha = RepoInfo(
      id: 'alpha',
      name: 'alpha',
      path: '/tmp/alpha',
      pinned: false,
      lastActivityAt: 0,
      isGitRepo: true,
      defaultBranch: 'main',
      currentBranch: 'main',
      worktrees: [wt('alpha-branch', isPrimary: true)],
    );
    final beta = RepoInfo(
      id: 'beta',
      name: 'beta',
      path: '/tmp/beta',
      pinned: false,
      lastActivityAt: 0,
      isGitRepo: true,
      defaultBranch: 'main',
      currentBranch: 'main',
      worktrees: [wt('beta-branch', isPrimary: true)],
    );

    final order = StateProvider<List<RepoInfo>>((ref) => [alpha, beta]);
    final container = ProviderContainer(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(const _EmptyStorage()),
        ),
        reposProvider.overrideWith((ref) => ReposState(ref.watch(order))),
        sessionsProvider.overrideWithValue(SessionsState(const [])),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Collapse beta (the second card).
    await tester.tap(find.text('beta'));
    await tester.pumpAndSettle();
    expect(find.text('beta-branch'), findsNothing);
    expect(find.text('alpha-branch'), findsOneWidget);

    // Beta becomes the most recently active and moves to the top.
    container.read(order.notifier).state = [beta, alpha];
    await tester.pumpAndSettle();

    // Beta is still the collapsed one; alpha did not inherit its state.
    expect(find.text('beta-branch'), findsNothing);
    expect(find.text('alpha-branch'), findsOneWidget);
  });
}
