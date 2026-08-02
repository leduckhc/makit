// Mobile worktree row disclosure, matching the desktop sidebar: a worktree with
// sessions carries a caret that folds them away; one without keeps the slot so
// branch names stay aligned down the card.
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

Worktree _worktree({List<String> sessionIds = const []}) => Worktree(
  id: '/tmp/feature',
  path: '/tmp/feature',
  branch: 'add-login',
  isPrimary: false,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: sessionIds,
);

Session _session(String id, String title) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: title,
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
);

Future<void> _pump(WidgetTester tester, List<Session> sessions) async {
  final worktree = _worktree(sessionIds: [for (final s in sessions) s.id]);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: ListView(
            children: [
              WorktreeRow(repo: _repo, worktree: worktree, sessions: sessions),
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

final _caret = find.byKey(const Key('worktreeCaret-/tmp/feature'));

void main() {
  testWidgets('the caret folds the sessions away and back', (tester) async {
    await _pump(tester, [_session('s1', 'first'), _session('s2', 'second')]);

    expect(find.text('first'), findsOneWidget);
    expect(_caret, findsOneWidget);

    await tester.tap(_caret);
    await tester.pumpAndSettle();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsNothing);
    // The branch itself stays — folding hides its sessions, not the worktree.
    expect(find.text('add-login'), findsOneWidget);

    await tester.tap(_caret);
    await tester.pumpAndSettle();

    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('tapping the branch row folds too', (tester) async {
    await _pump(tester, [_session('s1', 'first')]);

    await tester.tap(find.text('add-login'));
    await tester.pumpAndSettle();

    expect(find.text('first'), findsNothing);
  });

  testWidgets('a worktree with no sessions offers no caret', (tester) async {
    await _pump(tester, const []);

    expect(_caret, findsNothing);
    expect(find.text('add-login'), findsOneWidget);
  });
}
