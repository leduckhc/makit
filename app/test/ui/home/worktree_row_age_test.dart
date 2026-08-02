// Branch age on the mobile worktree row (matching the desktop sidebar's
// sub-row), plus the shared label helper both surfaces now use.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/ui/home/repo_chips.dart';
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

const _repo = RepoInfo(
  id: 'p1',
  name: 'demo',
  path: '/tmp/demo',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [],
);

Future<void> _pump(WidgetTester tester, DateTime? committedAt) async {
  final worktree = Worktree(
    id: '/tmp/feature',
    path: '/tmp/feature',
    branch: 'add-login',
    isPrimary: false,
    insertions: 0,
    deletions: 0,
    filesChanged: 0,
    sessionIds: const [],
    committedAt: committedAt,
  );
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: ListView(
            children: [
              WorktreeRow(repo: _repo, worktree: worktree, sessions: const []),
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

void main() {
  group('branchAgeLabel', () {
    test('scales from seconds to years', () {
      final now = DateTime.now();
      expect(
        branchAgeLabel(now.subtract(const Duration(seconds: 5))),
        'just now',
      );
      expect(
        branchAgeLabel(now.subtract(const Duration(minutes: 7))),
        '7m ago',
      );
      expect(branchAgeLabel(now.subtract(const Duration(hours: 5))), '5h ago');
      expect(branchAgeLabel(now.subtract(const Duration(days: 3))), '3d ago');
      expect(branchAgeLabel(now.subtract(const Duration(days: 65))), '2mo ago');
      expect(branchAgeLabel(now.subtract(const Duration(days: 800))), '2y ago');
    });

    test('is empty when the commit date is unknown', () {
      expect(branchAgeLabel(null), '');
    });
  });

  group('worktree row age', () {
    testWidgets('shows how long ago the branch last moved', (tester) async {
      await _pump(tester, DateTime.now().subtract(const Duration(days: 3)));

      expect(find.text('3d ago'), findsOneWidget);
    });

    testWidgets('shows nothing when the commit date is unknown', (
      tester,
    ) async {
      await _pump(tester, null);

      expect(find.textContaining('ago'), findsNothing);
      expect(find.text('add-login'), findsOneWidget);
    });
  });
}
