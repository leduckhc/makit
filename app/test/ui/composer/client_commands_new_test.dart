// Behavioural test for the `/new` client command (SPEC-30 decision 18): it must
// start the fresh agent in the CURRENT pane's worktree. Spawning with no
// worktree used to be legal, but since the client became responsible for
// resolving the worktree before spawning, a bare spawn silently runs the agent
// in the repo's primary checkout.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/client_commands.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// Records the spawn args `/new` forwards.
class _FakeStore extends StoreController {
  _FakeStore(super.ref);

  int spawnCount = 0;
  String? projectId;
  String? worktreePath;
  String? branch;

  @override
  Future<String> spawnSession(
    String source, {
    String? title,
    String? agent,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    spawnCount++;
    projectId = source;
    this.worktreePath = worktreePath;
    this.branch = branch;
    return 'spawned';
  }
}

Session _session({String? worktreePath, String? branch}) => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Current session',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  worktreePath: worktreePath,
  branch: branch,
);

Future<_FakeStore> _runNew(WidgetTester tester, Session session) async {
  late _FakeStore store;
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      sessionsProvider.overrideWithValue(SessionsState([session])),
      storeControllerProvider.overrideWith((ref) {
        store = _FakeStore(ref);
        return store;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(storeControllerProvider.notifier);

  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Consumer(
          builder: (ctx, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => handleClientCommand(
                '/new',
                context: ctx,
                ref: ref,
                sessionId: session.id,
              ),
              child: const Text('run'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/session/:id',
        builder: (context, state) =>
            Scaffold(body: Text('session ${state.pathParameters['id']}')),
      ),
    ],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.tap(find.text('run'));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('/new spawns in the current session\'s worktree', (tester) async {
    final store = await _runNew(
      tester,
      _session(worktreePath: '/tmp/wt/feat-x', branch: 'feat/x'),
    );

    expect(store.spawnCount, 1);
    expect(store.projectId, 'p1');
    expect(store.worktreePath, '/tmp/wt/feat-x');
    expect(store.branch, 'feat/x');
    expect(find.text('session spawned'), findsOneWidget);
  });

  testWidgets('/new is a no-op when the current session has no worktree', (
    tester,
  ) async {
    // A worktree-less session cannot say where the new agent should run, and a
    // bare spawn would land in the primary checkout — so refuse instead.
    final store = await _runNew(tester, _session());

    expect(store.spawnCount, 0);
    expect(find.textContaining('worktree'), findsOneWidget);
  });
}
