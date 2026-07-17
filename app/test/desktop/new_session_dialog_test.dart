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

void main() {
  testWidgets(
    'branch dropdown resets when switching to a repo with a disjoint branch set',
    (tester) async {
      // Two repos with NON-overlapping branches: alpha=[main], beta=[develop,foo].
      final repos = [
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
      ];

      final container = ProviderContainer(
        overrides: [
          reposProvider.overrideWithValue(ReposState(repos)),
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
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
                  onPressed: () => showNewSessionDialog(ctx, ref),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump(); // build dialog
      // agents.list has no server to answer it; let the request time out so
      // no Timer is left pending (fetchAgents swallows the timeout).
      await tester.pump(const Duration(seconds: 11));

      // Branch-from starts on alpha's default branch.
      expect(find.text('main'), findsWidgets);

      // Switch the repo dropdown (the first DropdownButtonFormField) to beta.
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('beta · develop').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // Switching repos also refetches the repo's open PRs; let that request
      // time out (no server) so no Timer is left pending, mirroring the
      // agents.list drain above.
      await tester.pump(const Duration(seconds: 11));

      // No "exactly one item" assertion, and the branch field adopted beta's
      // default rather than the now-invalid 'main'.
      expect(tester.takeException(), isNull);
      expect(find.text('develop'), findsWidgets);
    },
  );
}
