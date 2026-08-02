// Density contract for the mobile repo list (the "dense list, glass skin,
// touch-sized rows" direction): the list follows the desktop sidebar's structure
// and information density, but every interactive row stays a comfortable touch
// target rather than desktop's 24px pointer row.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
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

/// Apple's HIG minimum, and the floor every row in the list has to clear.
const double _kMinTouch = 44;

Session _session() => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'work on the login screen',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: 'Edited lib/main.dart',
);

RepoInfo _repo() => const RepoInfo(
  id: 'p1',
  name: 'demo',
  path: '/tmp/demo',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    Worktree(
      id: '/tmp/demo',
      path: '/tmp/demo',
      branch: 'main',
      isPrimary: true,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: ['s1'],
    ),
  ],
);

Future<void> _pump(WidgetTester tester) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: ListView(
            children: [
              RepoCard(repo: _repo(), sessions: [_session()]),
            ],
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

/// Height of the nearest tappable ancestor row containing [label].
double _rowHeight(WidgetTester tester, String label) {
  final row = find.ancestor(
    of: find.text(label),
    matching: find.byType(InkWell),
  );
  expect(row, findsWidgets, reason: 'no tappable row around "$label"');
  return tester.getSize(row.last).height;
}

void main() {
  testWidgets('the repo header is a touch-sized row', (tester) async {
    await _pump(tester);
    expect(_rowHeight(tester, 'demo'), greaterThanOrEqualTo(_kMinTouch));
  });

  testWidgets('the worktree row is a touch-sized row', (tester) async {
    await _pump(tester);
    expect(_rowHeight(tester, 'main'), greaterThanOrEqualTo(_kMinTouch));
  });

  testWidgets('the session row is a touch-sized row', (tester) async {
    await _pump(tester);
    final tile = find.ancestor(
      of: find.text('work on the login screen'),
      matching: find.byType(ListTile),
    );
    expect(tester.getSize(tile.first).height, greaterThanOrEqualTo(_kMinTouch));
  });

  testWidgets(
    'the PR pill is a touch-sized target that does not fatten the row',
    (tester) async {
      await _pumpWithPr(tester);

      final pill = find.ancestor(
        of: find.text('PR #42'),
        matching: find.byType(InkWell),
      );
      expect(pill, findsWidgets);
      final target = tester.getSize(pill.last);
      expect(
        target.height,
        greaterThanOrEqualTo(_kMinTouch),
        reason:
            'the pill opens the PR sheet, so it is a control in its own right',
      );

      // …and the row it sits in must not balloon to accommodate it: a 44px tap
      // area is meant to fill the row, not stack on top of its padding.
      final row = find.ancestor(
        of: find.text('add-login'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(row.last).height, lessThanOrEqualTo(48));
    },
  );
}

/// A repo whose feature worktree heads an open PR, for the pill above.
Future<void> _pumpWithPr(WidgetTester tester) async {
  const repo = RepoInfo(
    id: 'p1',
    name: 'demo',
    path: '/tmp/demo',
    pinned: false,
    lastActivityAt: 0,
    isGitRepo: true,
    defaultBranch: 'main',
    currentBranch: 'main',
    worktrees: [
      Worktree(
        id: '/tmp/demo/.wt/add-login',
        path: '/tmp/demo/.wt/add-login',
        branch: 'add-login',
        isPrimary: false,
        insertions: 0,
        deletions: 0,
        filesChanged: 0,
        sessionIds: [],
        pr: PullRequest(
          number: 42,
          url: 'https://github.com/o/r/pull/42',
          state: 'OPEN',
          title: 'Add the login screen',
          isDraft: false,
        ),
      ),
    ],
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: ListView(
            children: const [RepoCard(repo: repo, sessions: [])],
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
