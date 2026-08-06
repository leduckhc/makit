// The worktree starter's next-step bar, in the state the starter actually spends
// most of its life in: the repos snapshot does not carry the worktree yet,
// because the starter renders the moment the worktree is asked for.
//
// Separate from `worktree_starter_model_picker_test.dart` so the two concerns
// (draft model picks vs the PR bar's branch) stay independently readable.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/pr_bar.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';
import 'package:makit/desktop/chat/worktree_starter.dart';
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

const _agent = AgentDescriptor(
  id: 'zed',
  label: 'Zed',
  transport: 'acp',
  available: true,
);

/// Pump the starter for `feat/pr-actions` at `/tmp/wt`, with [repos] as the
/// snapshot — empty by default, which is the pre-snapshot state.
Future<void> _pump(
  WidgetTester tester, {
  List<RepoInfo> repos = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        agentsProvider.overrideWith((ref) => [_agent]),
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(const _EmptyStorage()),
        ),
        reposProvider.overrideWithValue(ReposState(repos)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: WorktreeStarter(
            worktree: SelectedWorktree(
              projectId: 'p1',
              path: '/tmp/wt',
              branch: 'feat/pr-actions',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The bar's sentence, flattened.
String _sentence(WidgetTester tester) => tester
    .widget<Text>(
      find
          .descendant(
            of: find.byType(PrComposerBar),
            matching: find.byType(Text),
          )
          .first,
    )
    .textSpan!
    .toPlainText();

void main() {
  testWidgets('the bar names the branch before the snapshot carries it', (
    tester,
  ) async {
    // `locateWorktree` returns null here. Without the branch passed through, the
    // identity degraded to `detached` — and worse, the wrap-up confirm would have
    // had no branch to name and would have sent no `expectBranch`.
    await _pump(tester);
    expect(_sentence(tester), contains('feat/pr-actions'));
    expect(_sentence(tester), isNot(contains('detached')));
  });

  testWidgets('it still prefers the snapshot once that catches up', (
    tester,
  ) async {
    // The fallback must not shadow real data: when the snapshot has the worktree,
    // its own branch and counts win.
    await _pump(
      tester,
      repos: [
        const RepoInfo(
          id: 'p1',
          name: 'makit',
          path: '/repo',
          pinned: false,
          lastActivityAt: 0,
          isGitRepo: true,
          defaultBranch: 'main',
          currentBranch: 'main',
          worktrees: [
            Worktree(
              id: '/tmp/wt',
              path: '/tmp/wt',
              branch: 'feat/renamed',
              isPrimary: false,
              insertions: 0,
              deletions: 0,
              filesChanged: 0,
              uncommittedFiles: 2,
              sessionIds: [],
            ),
          ],
        ),
      ],
    );
    expect(_sentence(tester), contains('feat/renamed'));
    expect(_sentence(tester), contains('2 files uncommitted'));
  });
}
