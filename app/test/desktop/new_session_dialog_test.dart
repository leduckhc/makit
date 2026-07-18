import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/store/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/new_session_dialog.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

/// Minimal in-memory secure storage so ConnectionController boots without
/// hitting platform channels (mirrors fake_data_onboarding_test).
class _EmptyStorage implements SecureStore {
  const _EmptyStorage();

  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

/// A StoreController whose PR lookups resolve instantly from a per-project map,
/// so tests exercise the PR flow without coupling to the transport timeout.
class _FakeStore extends StoreController {
  _FakeStore(super.ref, this._prs);

  final Map<String, List<OpenPr>> _prs;
  final List<int> createdFromPr = [];

  @override
  Future<List<OpenPr>> listOpenPrs(String projectId) async =>
      _prs[projectId] ?? const [];

  @override
  Future<({String path, String? branch})> createWorktreeFromPr(
    String projectId,
    int prNumber,
  ) async {
    createdFromPr.add(prNumber);
    return (path: '/tmp/wt/pr-$prNumber', branch: 'pr-$prNumber');
  }
}

OpenPr _pr(int number, String title, String head) => OpenPr(
  number: number,
  title: title,
  headRefName: head,
  isDraft: false,
  url: '',
);

Worktree _wt(
  String id, {
  required String branch,
  bool isPrimary = false,
  List<String> sessionIds = const [],
}) => Worktree(
  id: id,
  path: '/tmp/wt/$id',
  branch: branch,
  isPrimary: isPrimary,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: sessionIds,
);

RepoInfo _repo(
  String id,
  String name, {
  required String branch,
  required List<Worktree> worktrees,
}) => RepoInfo(
  id: id,
  name: name,
  path: '/tmp/$id',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: branch,
  currentBranch: branch,
  worktrees: worktrees,
);

/// Pump the New-worktree dialog with a [_FakeStore]. Returns the store so tests
/// can assert the commands the dialog issued.
Future<_FakeStore> _openDialog(
  WidgetTester tester, {
  required List<RepoInfo> repos,
  Map<String, List<OpenPr>> prs = const {},
  String? projectId,
}) async {
  late _FakeStore store;
  final container = ProviderContainer(
    overrides: [
      reposProvider.overrideWithValue(ReposState(repos)),
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
              onPressed: () =>
                  showNewSessionDialog(ctx, ref, projectId: projectId),
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
  testWidgets(
    'branch tab shows the dialog repo default branch (no repo selector)',
    (tester) async {
      // alpha=[main], beta=[develop,foo]. Opening for beta must show beta's
      // branches with no repo dropdown to switch away from it.
      await _openDialog(
        tester,
        projectId: 'b',
        repos: [
          _repo(
            'a',
            'alpha',
            branch: 'main',
            worktrees: [_wt('a-main', branch: 'main', isPrimary: true)],
          ),
          _repo(
            'b',
            'beta',
            branch: 'develop',
            worktrees: [
              _wt('b-dev', branch: 'develop', isPrimary: true),
              _wt('b-foo', branch: 'foo'),
            ],
          ),
        ],
      );

      // The repo selector is gone (the repo is fixed from the caller).
      expect(find.text('Repo'), findsNothing);
      expect(find.text('alpha · main'), findsNothing);
      // The branch tab adopted beta's default branch, and nothing threw.
      expect(tester.takeException(), isNull);
      expect(find.text('develop'), findsWidgets);
    },
  );

  testWidgets('PR tab lists the repo open PRs and forks the tapped one', (
    tester,
  ) async {
    final store = await _openDialog(
      tester,
      projectId: 'a',
      repos: [
        _repo(
          'a',
          'alpha',
          branch: 'main',
          worktrees: [_wt('a-main', branch: 'main', isPrimary: true)],
        ),
      ],
      prs: {
        'a': [
          _pr(11, 'Add login', 'feat/login'),
          _pr(12, 'Fix crash', 'fix/crash'),
        ],
      },
    );

    // Move to the PR tab (Branch is the default landing tab).
    await tester.tap(find.text('PR'));
    await tester.pumpAndSettle();

    expect(find.text('Add login'), findsOneWidget);
    expect(find.text('Fix crash'), findsOneWidget);

    // Tapping a PR forks a worktree from that PR number.
    await tester.tap(find.text('Add login'));
    await tester.pumpAndSettle();
    expect(store.createdFromPr, [11]);
  });
}
