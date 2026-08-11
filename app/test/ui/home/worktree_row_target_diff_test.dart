// The last link in the chain: server wire JSON -> `Worktree` -> RENDERED pixels.
//
// The server-side end-to-end test proves git -> diffStat -> WorktreeDTO -> wire
// frame (a stacked worktree drops from +23 to +3 after `worktree.setTarget`), and
// the model test proves wire JSON -> `Worktree.targetBranch`/`showsDiff`. Neither
// proves the row actually PAINTS the corrected number, which is the only part
// the user ever sees. This closes that gap by feeding the exact JSON shape the
// server emits into the real `WorktreeRow`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
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

/// A worktree exactly as `WorktreeDTO` arrives on the wire.
Worktree fromWire({
  required int insertions,
  required int deletions,
  String? targetBranch,
  bool targetResolved = true,
}) {
  final w = Worktree.fromJson({
    'id': '/wt/child',
    'path': '/wt/child',
    'branch': 'feat/child',
    'isPrimary': false,
    'targetBranch': targetBranch,
    'targetResolved': targetResolved,
    'insertions': insertions,
    'deletions': deletions,
    'filesChanged': 2,
    'uncommittedFiles': 0,
    'aheadCount': 1,
    'behindCount': 0,
    'committedAt': null,
    'pr': null,
    'sessionIds': <String>[],
  });
  expect(w, isNotNull, reason: 'the wire shape must decode');
  return w!;
}

Future<void> pumpRow(WidgetTester tester, Worktree worktree) async {
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
  testWidgets('renders the target-relative diff, not the inflated one', (
    tester,
  ) async {
    // What the server now sends for a worktree targeting its parent.
    await pumpRow(
      tester,
      fromWire(insertions: 3, deletions: 1, targetBranch: 'feat/parent'),
    );
    expect(find.text('+3'), findsOneWidget);
    expect(find.text('\u22121'), findsOneWidget);
    // The pre-fix figure (parent's work counted as the child's) must be absent.
    expect(find.text('+23'), findsNothing);
  });

  testWidgets('suppresses the pill when the target could not be resolved', (
    tester,
  ) async {
    // R7/B5: the numbers here are working-tree-only, so painting them would
    // assert a committed delta that was never measured. The failure mode is a
    // plausible SMALL count, not a zero, which is why this must be suppressed
    // rather than left to `hasChanges`.
    await pumpRow(
      tester,
      fromWire(
        insertions: 3,
        deletions: 1,
        targetBranch: 'feat/deleted',
        targetResolved: false,
      ),
    );
    expect(find.text('+3'), findsNothing);
    expect(find.text('\u22121'), findsNothing);
  });

  testWidgets('still renders working-tree numbers when there is no target', (
    tester,
  ) async {
    // The primary checkout and detached worktrees have no target; their numbers
    // legitimately mean "uncommitted" and must not be suppressed.
    await pumpRow(
      tester,
      fromWire(insertions: 3, deletions: 1, targetBranch: null),
    );
    expect(find.text('+3'), findsOneWidget);
  });

  testWidgets('an older server (no target fields) keeps rendering', (
    tester,
  ) async {
    // Forward compatibility: `targetResolved` defaults to true, so a stale
    // server does not blank every pill in the list.
    final w = Worktree.fromJson({
      'id': '/wt/child',
      'path': '/wt/child',
      'branch': 'feat/child',
      'isPrimary': false,
      'insertions': 7,
      'deletions': 0,
      'filesChanged': 1,
      'sessionIds': <String>[],
    })!;
    await pumpRow(tester, w);
    expect(find.text('+7'), findsOneWidget);
  });
}
