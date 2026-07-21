// Regression test for the "start a session in an EXISTING worktree" flow
// (WorktreeStartView). Sending the first message must bind the freshly spawned
// (still-pending) session into the REAL worktree tree the user is looking at —
// not misfile it into a virtual `draft:<id>` tree. A pending draft has no
// worktreePath yet, so routing selection through selectSessionExclusive (which
// only distinguishes on worktreePath) bounced the pane onto a `draft:` tree
// and, once the session materialized, back to the empty start view — losing
// the just-sent turn from view.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/desktop/chat/harness_picker.dart';
import 'package:makit/desktop/chat/panes/pane_tree_controller.dart';
import 'package:makit/desktop/chat/pr_actions.dart';
import 'package:makit/desktop/chat/pr_bar.dart';
import 'package:makit/desktop/chat/selected_session.dart';
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

/// A store whose spawnSession synchronously seeds a pending draft session bound
/// to an existing worktree (worktreePath still null — it only gains one once
/// the server promotes it), mirroring what the real server snapshot delivers
/// before the ack resolves.
class _FakeStore extends StoreController {
  _FakeStore(super.ref);

  final List<String> sent = [];

  @override
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? baseBranch,
    String? worktreePath,
    String? branch,
  }) async {
    const sid = 's-new';
    state = state.copyWith(
      sessions: [
        Session(
          id: sid,
          projectId: projectId,
          agent: agent ?? 'codex',
          title: 'new session',
          status: SessionStatus.idle,
          policy: ApprovalPolicy.askOnRisky,
          pending: true,
          branch: branch,
          worktreePath: null,
        ),
      ],
    );
    return sid;
  }

  @override
  void appendOptimisticMessage(String sessionId, String text) {}

  @override
  void sendMessage(String sessionId, String text) => sent.add(text);

  /// Seed a repos snapshot so [reposProvider] resolves a PR for [_wt.path].
  void seedRepoWithPr(PullRequest pr) {
    state = state.copyWith(
      repos: [
        RepoInfo(
          id: 'p1',
          name: 'repo',
          path: '/tmp/repo',
          pinned: false,
          lastActivityAt: 0,
          isGitRepo: true,
          defaultBranch: 'main',
          currentBranch: 'main',
          worktrees: [
            Worktree(
              id: _wt.path,
              path: _wt.path,
              branch: _wt.branch,
              isPrimary: false,
              insertions: 0,
              deletions: 0,
              filesChanged: 0,
              sessionIds: const [],
              pr: pr,
            ),
          ],
        ),
      ],
    );
  }
}

const _wt = SelectedWorktree(
  projectId: 'p1',
  path: '/tmp/wt-existing',
  branch: 'feat/login',
);

void main() {
  testWidgets(
    'sending in an existing worktree binds the session into that worktree '
    'tree, not a draft: tree',
    (tester) async {
      late _FakeStore store;
      final container = ProviderContainer(
        overrides: [
          agentsProvider.overrideWith(
            (ref) async => const [
              AgentDescriptor(
                id: 'codex',
                label: 'Codex',
                transport: 'stdio',
                available: true,
              ),
            ],
          ),
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          storeControllerProvider.overrideWith((ref) {
            store = _FakeStore(ref);
            return store;
          }),
        ],
      );
      addTearDown(container.dispose);

      // The user clicked the existing sessionless worktree first.
      container.read(paneTreeControllerProvider.notifier).selectWorktree(_wt);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: WorktreeStartView(worktree: _wt)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hello there');
      await tester.pump();
      await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp).last);
      await tester.pumpAndSettle();

      expect(store.sent, ['hello there']);
      expect(container.read(selectedSessionProvider), 's-new');
      final current = container.read(paneTreeControllerProvider).current!;
      expect(current.worktree.path, _wt.path);
      expect(
        container.read(paneTreeControllerProvider.notifier).activeLeafSessionId,
        's-new',
        reason: 'session pinned to the real tree active leaf',
      );
      expect(
        container
            .read(paneTreeControllerProvider)
            .trees
            .containsKey('draft:s-new'),
        isFalse,
      );
    },
  );

  testWidgets(
    'shows the PR status pill when the existing worktree heads an open PR',
    (tester) async {
      late _FakeStore store;
      final container = ProviderContainer(
        overrides: [
          agentsProvider.overrideWith(
            (ref) async => const [
              AgentDescriptor(
                id: 'codex',
                label: 'Codex',
                transport: 'stdio',
                available: true,
              ),
            ],
          ),
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          storeControllerProvider.overrideWith((ref) {
            store = _FakeStore(ref);
            return store;
          }),
        ],
      );
      addTearDown(container.dispose);

      // Force the store override to run so `store` is assigned before we seed.
      container.read(storeControllerProvider.notifier);
      store.seedRepoWithPr(
        const PullRequest(
          number: 88,
          url: 'https://github.com/o/r/pull/88',
          state: 'OPEN',
          title: 't',
          isDraft: false,
          checkRollup: 'pass',
          checks: [],
        ),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: WorktreeStartView(worktree: _wt)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PrStatusPill), findsOneWidget);
      expect(find.text('PR #88'), findsOneWidget);
    },
  );

  testWidgets(
    'the PR actions button inserts the Create PR prompt into the composer',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          agentsProvider.overrideWith(
            (ref) async => const [
              AgentDescriptor(
                id: 'codex',
                label: 'Codex',
                transport: 'stdio',
                available: true,
              ),
            ],
          ),
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          storeControllerProvider.overrideWith((ref) => _FakeStore(ref)),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: WorktreeStartView(worktree: _wt)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The actions button shows even with no PR (it's the path to getting one).
      expect(find.text('Create PR'), findsOneWidget);
      await tester.tap(find.text('Create PR'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, PrPromptAction.createPr.defaultPrompt),
        findsOneWidget,
      );
    },
  );
}
