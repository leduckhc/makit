import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_providers.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/repo_card.dart';
import 'package:makit/ui/home/start_session.dart';

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

  /// How many times the flow started: the sheet opens only after this resolves,
  /// which is the window a second tap can slip through.
  int agentFetches = 0;

  @override
  Future<List<AgentDescriptor>> fetchAgents() async {
    agentFetches++;
    return agents;
  }

  @override
  Future<List<OpenPr>> listOpenPrs(String projectId) async => const [];

  @override
  Future<({String path, String? branch})> createWorktree(
    String projectId, {
    String? targetBranch,
    String? branchName,
  }) async {
    createdFrom.add(targetBranch);
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
  StatusCenter? status,
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
        path: '/repos/session/:id',
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
      if (status != null) statusCenterProvider.overrideWithValue(status),
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
  await tester.tap(find.byTooltip('Repo actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('New session').last);
  await tester.pumpAndSettle();
}

void main() {
  // Order-independence: the guard is library-level, so a leftover from one test
  // would silently disable the flow in the next.
  setUp(resetStartSessionFlowGuard);

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
    final center = StatusCenter();
    addTearDown(center.dispose);
    final store = await _pump(tester, agents: [_agent('pi')], status: center);
    store.spawnThrows = true;

    await _openNewSessionSheet(tester);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    // The worktree was created, spawn threw, so the worktree is removed again
    // (a retry must not orphan it) and the failure is recorded in Activity.
    expect(store.createdFrom, ['main']);
    expect(store.removedWorktrees, ['/tmp/demo-wt']);
    expect(center.events.single.title, 'Could not start session');
    expect(center.events.single.detail, contains('spawn failed'));
  });

  testWidgets('a double tap on + starts one session flow, not two', (
    tester,
  ) async {
    final store = await _pump(tester, agents: [_agent('pi')]);

    // The `+` awaits fetchAgents before the sheet appears, so an impatient
    // second tap in that window used to open a second sheet — and could then
    // create a second worktree and spawn twice.
    final plus = find.byKey(const Key('newSessionInWorktree-/tmp/demo'));
    expect(plus, findsWidgets);
    await tester.tap(plus.first, warnIfMissed: false);
    await tester.tap(plus.first, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(store.agentFetches, 1, reason: 'the second tap must be swallowed');
    expect(find.text('Start'), findsOneWidget, reason: 'exactly one sheet');

    // Dismiss so the flow completes and releases the guard.
    await tester.tapAt(const Offset(400, 40));
    await tester.pumpAndSettle();
  });
}
