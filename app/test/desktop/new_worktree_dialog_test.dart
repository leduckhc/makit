// Widget tests for the SPEC-30 New-worktree dialog: it asks ONLY where the
// worktree comes from — a repository selector plus a New-branch / From-PR
// source toggle. There is no harness grid and no first-message composer (those
// belong to the Choose-a-harness starter you land on afterwards). Confirming
// creates the worktree and activates its group; it never spawns a session.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/harness_picker.dart' show HarnessCard;
import 'package:makit/desktop/chat/new_worktree_dialog.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// Records the worktree commands the dialog issues. Spawning a session must
/// never happen from this dialog, so [spawnCount] must stay 0.
class _FakeStore extends StoreController {
  _FakeStore(super.ref, this._prs);

  final Map<String, List<OpenPr>> _prs;

  int spawnCount = 0;
  final List<int> createdFromPr = [];
  final List<String?> createdWorktreeBases = [];
  final List<String?> createdWorktreeNames = [];

  @override
  Future<List<OpenPr>> listOpenPrs(String projectId) async =>
      _prs[projectId] ?? const [];

  @override
  Future<({String path, String? branch})> createWorktree(
    String projectId, {
    String? baseBranch,
    String? branchName,
  }) async {
    createdWorktreeBases.add(baseBranch);
    createdWorktreeNames.add(branchName);
    return (path: '/tmp/wt/new-$baseBranch', branch: 'auto/$baseBranch');
  }

  @override
  Future<({String path, String? branch})> createWorktreeFromPr(
    String projectId,
    int prNumber,
  ) async {
    createdFromPr.add(prNumber);
    return (path: '/tmp/wt/pr-$prNumber', branch: 'pr-$prNumber');
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
    return 's-should-not-happen';
  }
}

const _pi = AgentDescriptor(
  id: 'pi',
  label: 'Pi',
  transport: 'acp',
  available: true,
);

Worktree _wt(String id, {required String branch, bool isPrimary = false}) =>
    Worktree(
      id: id,
      path: '/tmp/wt/$id',
      branch: branch,
      isPrimary: isPrimary,
      insertions: 0,
      deletions: 0,
      filesChanged: 0,
      sessionIds: const [],
    );

RepoInfo _repo() => RepoInfo(
  id: 'p1',
  name: 'makit',
  path: '/tmp/p1',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [
    _wt('main', branch: 'main', isPrimary: true),
    _wt('login', branch: 'feat/login'),
  ],
);

Future<({_FakeStore store, ProviderContainer container, SelectedWorktree? result})>
_open(
  WidgetTester tester, {
  Map<String, List<OpenPr>> prs = const {},
}) async {
  late _FakeStore store;
  SelectedWorktree? result;
  var opened = false;
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      reposProvider.overrideWithValue(ReposState([_repo()])),
      agentsProvider.overrideWith((ref) async => [_pi]),
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      storeControllerProvider.overrideWith((ref) {
        store = _FakeStore(ref, prs);
        return store;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (ctx, ref, _) => TextButton(
              onPressed: () async {
                result = await showNewWorktreeDialog(ctx, ref);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  container.read(storeControllerProvider.notifier);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  opened = true;
  expect(opened, isTrue);
  // `result` is filled asynchronously once the dialog resolves; callers that
  // need it read the returned record after pumping.
  return (store: store, container: container, result: result);
}

void main() {
  testWidgets('shows a repo selector and New-branch / From-PR sources', (
    tester,
  ) async {
    await _open(tester);

    expect(find.text('New worktree'), findsOneWidget);
    expect(find.byKey(const ValueKey('wt-repo-picker')), findsOneWidget);
    expect(find.text('New branch'), findsOneWidget);
    expect(find.text('From PR'), findsOneWidget);
    // New branch is the default: its base-branch picker is shown.
    expect(find.byKey(const ValueKey('wt-branch-p1')), findsOneWidget);
  });

  testWidgets('has no harness grid and no first-message composer', (
    tester,
  ) async {
    await _open(tester);

    expect(find.byType(HarnessCard), findsNothing);
    expect(find.byType(Composer), findsNothing);
    expect(find.text('Create worktree'), findsOneWidget);
  });

  testWidgets('the source toggle switches to the PR picker', (tester) async {
    await _open(tester);

    await tester.tap(find.text('From PR'));
    await tester.pumpAndSettle();
    // No PRs seeded → the empty hint, and the branch picker is gone.
    expect(
      find.text('No open pull requests (or GitHub CLI is unavailable).'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('wt-branch-p1')), findsNothing);
  });

  testWidgets(
    'Create worktree forks off the base branch and activates its group, '
    'without spawning a session',
    (tester) async {
      final opened = await _open(tester);

      await tester.tap(find.text('Create worktree'));
      await tester.pumpAndSettle();

      expect(opened.store.createdWorktreeBases, ['main']);
      expect(opened.store.createdWorktreeNames, [null]);
      expect(opened.store.spawnCount, 0);

      // The created worktree's group is now active and scoped to it.
      final groups = opened.container.read(groupsControllerProvider);
      expect(groups.active.kind, GroupKind.worktree);
      expect(groups.active.projectId, 'p1');
      expect(groups.active.worktreePath, '/tmp/wt/new-main');

      // The dialog is gone.
      expect(find.text('New worktree'), findsNothing);
    },
  );

  testWidgets('Cancel creates nothing', (tester) async {
    final opened = await _open(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(opened.store.createdWorktreeBases, isEmpty);
    expect(opened.store.createdFromPr, isEmpty);
    expect(opened.store.spawnCount, 0);
    // Still a single fresh board — no group was minted.
    final groups = opened.container.read(groupsControllerProvider);
    expect(groups.groups.length, 1);
    expect(groups.active.kind, GroupKind.board);
    expect(find.text('New worktree'), findsNothing);
  });

  testWidgets('activateGroup: false places the worktree without switching group', (
    tester,
  ) async {
    late _FakeStore store;
    SelectedWorktree? result;
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        reposProvider.overrideWithValue(ReposState([_repo()])),
        agentsProvider.overrideWith((ref) async => [_pi]),
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(const _EmptyStorage()),
        ),
        storeControllerProvider.overrideWith((ref) {
          store = _FakeStore(ref, const {});
          return store;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (ctx, ref, _) => TextButton(
                onPressed: () async {
                  result = await showNewWorktreeDialog(
                    ctx,
                    ref,
                    activateGroup: false,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create worktree'));
    await tester.pumpAndSettle();

    expect(store.createdWorktreeBases, ['main']);
    expect(result, isNotNull);
    expect(result!.path, '/tmp/wt/new-main');
    // No group was activated: still the single fresh board.
    final groups = container.read(groupsControllerProvider);
    expect(groups.groups.length, 1);
    expect(groups.active.kind, GroupKind.board);
  });
}
