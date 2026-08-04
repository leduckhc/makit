import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/repo_card.dart';

/// In-memory secure storage so ConnectionController boots without platform
/// channels (mirrors the desktop dialog test).
class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// A StoreController that serves a fixed agent catalog and records the args of
/// the last `spawnSession` so the test can assert the sheet forwarded them.
class _FakeStore extends StoreController {
  _FakeStore(super.ref, this.agents);

  final List<AgentDescriptor> agents;
  int spawnCount = 0;
  String? spawnedAgent;
  String? spawnedWorktreePath;
  String? spawnedBranch;
  List<ConfigOptionPick>? spawnedPicks;

  /// Recorded `createWorktree` calls: the base branch each fork asked for.
  final List<String?> createdFrom = [];

  /// When true, `spawnSession` throws — to exercise the create-then-rollback
  /// path. `removedWorktrees` records each `removeWorktree` the rollback made.
  bool spawnThrows = false;
  final List<String> removedWorktrees = [];

  @override
  Future<void> removeWorktree(String projectId, String path) async {
    removedWorktrees.add(path);
  }

  @override
  Future<List<AgentDescriptor>> fetchAgents() async => agents;

  @override
  Future<List<OpenPr>> listOpenPrs(String projectId) async => const [];

  @override
  Future<({String path, String? branch})> createWorktree(
    String projectId, {
    String? baseBranch,
    String? branchName,
  }) async {
    createdFrom.add(baseBranch);
    return (path: '/tmp/demo-wt', branch: 'forked');
  }

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
    spawnedAgent = agent;
    spawnedWorktreePath = worktreePath;
    spawnedBranch = branch;
    spawnedPicks = configOptions;
    if (spawnThrows) throw StateError('spawn failed');
    return 'new-sess';
  }
}

AgentDescriptor _agent(
  String id, {
  String transport = 'acp',
  List<SessionConfigOption> configOptions = const [],
}) => AgentDescriptor(
  id: id,
  label: id,
  transport: transport,
  available: true,
  configOptions: configOptions,
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
      sessionIds: [],
    ),
  ],
);

Future<_FakeStore> _pump(
  WidgetTester tester, {
  required List<AgentDescriptor> agents,
}) async {
  late _FakeStore store;
  final repo = _repo();
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
      GoRoute(
        path: '/session/:id',
        builder: (context, state) =>
            Scaffold(body: Text('session ${state.pathParameters['id']}')),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      storeControllerProvider.overrideWith((ref) {
        store = _FakeStore(ref, agents);
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

/// Open the new-session sheet the way a user now reaches the full picker: the
/// repo header's overflow menu. The card footer is "New worktree" — every
/// worktree row has its own `+` for starting a session on a known branch.
Future<void> _openNewSessionSheet(WidgetTester tester) async {
  await tester.tap(find.byIcon(PhosphorIconsRegular.dotsThree));
  await tester.pumpAndSettle();
  await tester.tap(find.text('New session').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('forwards the config picks chosen in the sheet to spawnSession', (
    tester,
  ) async {
    final store = await _pump(
      tester,
      agents: [
        _agent(
          'pi',
          configOptions: [
            const SessionConfigOption(
              id: 'model',
              name: 'Model',
              category: 'model',
              type: ConfigOptionType.select,
              currentValue: 'gpt-5',
              options: [
                ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
                ConfigOptionValue(value: 'sonnet', name: 'Sonnet'),
              ],
            ),
          ],
        ),
      ],
    );

    await _openNewSessionSheet(tester);

    // Pick a non-default model, then Start.
    await tester.tap(find.text('GPT-5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sonnet').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(store.spawnCount, 1);
    expect(store.spawnedAgent, 'pi');
    expect(store.spawnedPicks, isNotNull);
    expect(store.spawnedPicks!.single.id, 'model');
    expect(store.spawnedPicks!.single.value, 'sonnet');
    // Landed on the new session.
    expect(find.text('session new-sess'), findsOneWidget);
  });

  testWidgets('always opens the sheet, even with nothing to configure', (
    tester,
  ) async {
    final store = await _pump(tester, agents: [_agent('pi')]);

    await _openNewSessionSheet(tester);

    // One harness, one branch, one worktree, no PRs, no config options: the
    // sheet still opens instead of silently spawning.
    expect(find.text('New session'), findsWidgets);
    expect(find.text('Start'), findsOneWidget);
    expect(store.spawnCount, 0);
  });

  testWidgets('forks the worktree before spawning into it', (tester) async {
    final store = await _pump(tester, agents: [_agent('pi')]);

    await _openNewSessionSheet(tester);
    // "New branch" is the default source, so Start forks off the base branch
    // client-side and spawns INTO the created worktree.
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(store.createdFrom, ['main']);
    expect(store.spawnCount, 1);
    expect(store.spawnedWorktreePath, '/tmp/demo-wt');
    expect(store.spawnedBranch, 'forked');
  });

  testWidgets('rolls back the freshly forked worktree when spawn fails', (
    tester,
  ) async {
    final store = await _pump(tester, agents: [_agent('pi')]);
    store.spawnThrows = true;

    await _openNewSessionSheet(tester);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    // The worktree was created, spawn threw, so the worktree is removed again
    // (a retry must not orphan it) and the failure surfaces in a SnackBar.
    expect(store.createdFrom, ['main']);
    expect(store.removedWorktrees, ['/tmp/demo-wt']);
    expect(find.textContaining('Could not start session'), findsOneWidget);
  });
}
