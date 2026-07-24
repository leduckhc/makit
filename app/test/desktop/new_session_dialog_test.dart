// Widget tests for the SPEC-27 New-session dialog: the worktree source toggle
// switches panels; selecting a harness card swaps the composer's config pills
// to that harness's cached configOptions; send resolves the worktree and calls
// spawnSession with the pending picks, then closes; ✕/Escape close with no
// spawn.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/desktop/chat/new_session_dialog.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// Records the commands the dialog issues and seeds a real (worktree-bound)
/// session on spawn so selection can resolve it.
class _FakeStore extends StoreController {
  _FakeStore(super.ref, this._prs);

  final Map<String, List<OpenPr>> _prs;

  int spawnCount = 0;
  String? spawnAgent;
  String? spawnWorktreePath;
  String? spawnBranch;
  List<ConfigOptionPick>? spawnPicks;
  final List<String> sent = [];
  final List<int> createdFromPr = [];
  final List<String?> createdWorktreeBases = [];

  @override
  Future<List<OpenPr>> listOpenPrs(String projectId) async =>
      _prs[projectId] ?? const [];

  @override
  Future<({String path, String? branch})> createWorktree(
    String projectId, {
    String? baseBranch,
  }) async {
    createdWorktreeBases.add(baseBranch);
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
    String? baseBranch,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    spawnCount++;
    spawnAgent = agent;
    spawnWorktreePath = worktreePath;
    spawnBranch = branch;
    spawnPicks = configOptions;
    const sid = 's-new';
    state = state.copyWith(
      sessions: [
        Session(
          id: sid,
          projectId: projectId,
          agent: agent ?? 'pi',
          title: 'new',
          status: SessionStatus.idle,
          policy: ApprovalPolicy.askOnRisky,
          pending: true,
          branch: branch,
          worktreePath: worktreePath,
        ),
      ],
    );
    return sid;
  }

  @override
  void appendOptimisticMessage(String sessionId, String text) {}

  @override
  void sendMessage(String sessionId, String text) => sent.add(text);
}

SessionConfigOption _modelOption(String value, String name) =>
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      type: ConfigOptionType.select,
      currentValue: value,
      options: [ConfigOptionValue(value: value, name: name)],
    );

const _webOption = SessionConfigOption(
  id: 'web',
  name: 'Web search',
  type: ConfigOptionType.boolean,
  currentValue: false,
);

final _pi = AgentDescriptor(
  id: 'pi',
  label: 'Pi',
  transport: 'acp',
  available: true,
  configOptions: [_modelOption('pi-m', 'PiModel'), _webOption],
);

final _codex = AgentDescriptor(
  id: 'codex',
  label: 'Codex',
  transport: 'native',
  available: true,
  configOptions: [_modelOption('cx-m', 'CodexModel')],
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

Future<_FakeStore> _open(
  WidgetTester tester, {
  List<AgentDescriptor> agents = const [],
  Map<String, List<OpenPr>> prs = const {},
}) async {
  late _FakeStore store;
  // The dialog is tall (worktree + harness grid + composer); give the test
  // window room so the composer isn't pushed offstage.
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      reposProvider.overrideWithValue(ReposState([_repo()])),
      agentsProvider.overrideWith((ref) async => agents),
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
              onPressed: () => showNewSessionDialog(ctx, ref, projectId: 'p1'),
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
  return store;
}

void main() {
  testWidgets('the worktree source toggle switches panels', (tester) async {
    await _open(tester, agents: [_pi]);

    // Existing is the default source: its worktree dropdown is shown.
    expect(find.byKey(const ValueKey('existing-p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('branch-p1')), findsNothing);

    await tester.tap(find.text('New branch'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('branch-p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('existing-p1')), findsNothing);

    await tester.tap(find.text('From PR'));
    await tester.pumpAndSettle();
    // No PRs seeded → the empty hint (still no branch/existing dropdowns).
    expect(
      find.text('No open pull requests (or GitHub CLI is unavailable).'),
      findsOneWidget,
    );
  });

  testWidgets('selecting a harness card swaps the config pills', (tester) async {
    await _open(tester, agents: [_pi, _codex]);

    // Default selection is the first available agent (Pi) → its model pill.
    expect(find.text('PiModel'), findsOneWidget);
    expect(find.text('CodexModel'), findsNothing);

    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();

    expect(find.text('CodexModel'), findsOneWidget);
    expect(find.text('PiModel'), findsNothing);
  });

  testWidgets('send resolves an existing worktree and spawns with picks, then '
      'closes', (tester) async {
    final store = await _open(tester, agents: [_pi]);

    // Toggle the boolean config option (a pending pick, no session yet).
    await tester.tap(find.text('Web search'));
    await tester.pumpAndSettle();

    // The default existing worktree is the primary (first) worktree.
    await tester.enterText(find.byType(TextField), 'start me up');
    await tester.pump();
    await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp).last);
    await tester.pumpAndSettle();

    expect(store.spawnCount, 1);
    expect(store.spawnAgent, 'pi');
    expect(store.spawnWorktreePath, '/tmp/wt/main');
    expect(store.spawnPicks, isNotNull);
    expect(store.spawnPicks!.single.id, 'web');
    expect(store.spawnPicks!.single.value, true);
    expect(store.sent, ['start me up']);
    // The dialog closed (no side effects to tear down).
    expect(find.text('New session'), findsNothing);
  });

  testWidgets('New branch send forks a worktree off the base branch', (
    tester,
  ) async {
    final store = await _open(tester, agents: [_pi]);

    await tester.tap(find.text('New branch'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'fork it');
    await tester.pump();
    await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp).last);
    await tester.pumpAndSettle();

    expect(store.createdWorktreeBases, ['main']);
    expect(store.spawnWorktreePath, '/tmp/wt/new-main');
    expect(store.spawnCount, 1);
  });

  testWidgets('✕ closes the dialog without spawning', (tester) async {
    final store = await _open(tester, agents: [_pi]);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('New session'), findsNothing);
    expect(store.spawnCount, 0);
  });

  testWidgets('Escape closes the dialog without spawning', (tester) async {
    final store = await _open(tester, agents: [_pi]);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('New session'), findsNothing);
    expect(store.spawnCount, 0);
  });
}
