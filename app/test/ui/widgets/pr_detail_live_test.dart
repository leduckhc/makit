// R5: the detail sheet must re-derive its facts, not freeze them at open time.
//
// `PrDetailBody` used to be a `StatelessWidget` handed a `PrStatus` computed by
// its caller. That was stale-by-construction the moment the sheet header started
// hosting the "Lands in" picker: change where a worktree lands from inside the
// sheet and it kept painting the previous +/- numbers until you closed and
// reopened it — on the one screen where the user had just acted.
//
// These tests pump the sheet, then push a NEW repos snapshot underneath it and
// assert the open sheet follows.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/widgets/pr_detail.dart';
import 'package:makit/ui/widgets/pr_signals.dart';

Worktree wt({
  required int insertions,
  String? targetBranch = 'feat/parent',
  bool targetResolved = true,
  String? retargetedFrom,
}) => Worktree(
  id: '/wt/child',
  path: '/wt/child',
  branch: 'feat/child',
  isPrimary: false,
  insertions: insertions,
  deletions: 0,
  filesChanged: 1,
  sessionIds: const [],
  targetBranch: targetBranch,
  targetResolved: targetResolved,
  retargetedFrom: retargetedFrom,
);

RepoInfo repoWith(Worktree w) => RepoInfo(
  id: 'p1',
  name: 'demo',
  path: '/tmp/demo',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [w],
);

/// Pump the sheet body against a mutable repos state.
Future<void> pumpSheet(
  WidgetTester tester,
  ValueNotifier<ReposState> repos, {
  String? worktreePath = '/wt/child',
}) async {
  await tester.pumpWidget(
    ValueListenableBuilder<ReposState>(
      valueListenable: repos,
      builder: (context, value, _) => ProviderScope(
        overrides: [reposProvider.overrideWithValue(value)],
        child: MaterialApp(
          home: Scaffold(
            body: PrDetailBody(
              // Deliberately WRONG open-time facts, so anything the sheet paints
              // from them instead of from the snapshot is visible.
              status: prStatus(pr: null, branch: 'feat/child'),
              pr: null,
              onRun: (_) {},
              projectId: 'p1',
              worktreePath: worktreePath,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an open sheet picks up new diff numbers from the snapshot', (
    tester,
  ) async {
    final repos = ValueNotifier(ReposState([repoWith(wt(insertions: 23))]));
    addTearDown(repos.dispose);
    await pumpSheet(tester, repos);
    expect(find.text('+23'), findsOneWidget);

    // A retarget lands: the server recomputes and broadcasts. Nothing else
    // happens — no reopen, no navigation, no user interaction.
    repos.value = ReposState([repoWith(wt(insertions: 3))]);
    await tester.pumpAndSettle();

    expect(find.text('+3'), findsOneWidget);
    expect(
      find.text('+23'),
      findsNothing,
      reason: 'the sheet must not keep painting open-time facts',
    );
  });

  testWidgets('the header names the target it lands in', (tester) async {
    final repos = ValueNotifier(ReposState([repoWith(wt(insertions: 3))]));
    addTearDown(repos.dispose);
    await pumpSheet(tester, repos);
    expect(find.text('feat/parent'), findsOneWidget);
  });

  testWidgets('an open sheet follows a target change', (tester) async {
    final repos = ValueNotifier(ReposState([repoWith(wt(insertions: 3))]));
    addTearDown(repos.dispose);
    await pumpSheet(tester, repos);
    expect(find.text('feat/parent'), findsOneWidget);

    repos.value = ReposState([
      repoWith(wt(insertions: 23, targetBranch: 'main')),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('main'), findsOneWidget);
    expect(find.text('feat/parent'), findsNothing);
  });

  testWidgets('an unresolvable target suppresses the diff and says why', (
    tester,
  ) async {
    final repos = ValueNotifier(
      ReposState([repoWith(wt(insertions: 3, targetResolved: false))]),
    );
    addTearDown(repos.dispose);
    await pumpSheet(tester, repos);
    // Step 8: the state is SAID, not merely hidden — suppression alone leaves the
    // row indistinguishable from a clean worktree.
    expect(find.textContaining('nowhere to land'), findsOneWidget);
    expect(find.text('+3'), findsNothing);
  });

  testWidgets('an automatic retarget is announced in the sheet', (
    tester,
  ) async {
    // Rule 4 / B7 chose "fall back to the default, but say so". The saying-so has
    // to actually reach a surface, or the fallback is silent after all — which is
    // the failure mode the rule exists to prevent.
    final repos = ValueNotifier(
      ReposState([
        repoWith(
          wt(
            insertions: 3,
            targetBranch: 'main',
            retargetedFrom: 'feat/parent',
          ),
        ),
      ]),
    );
    addTearDown(repos.dispose);
    await pumpSheet(tester, repos);
    expect(find.textContaining('was feat/parent'), findsOneWidget);
    expect(find.textContaining('now main'), findsOneWidget);
  });

  testWidgets('the announcement goes away once the target is owned', (
    tester,
  ) async {
    final repos = ValueNotifier(
      ReposState([
        repoWith(
          wt(
            insertions: 3,
            targetBranch: 'main',
            retargetedFrom: 'feat/parent',
          ),
        ),
      ]),
    );
    addTearDown(repos.dispose);
    await pumpSheet(tester, repos);
    expect(find.textContaining('was feat/parent'), findsOneWidget);

    // The user picks a target: the server clears the note, so the sheet must stop
    // announcing without needing to be reopened.
    repos.value = ReposState([
      repoWith(wt(insertions: 3, targetBranch: 'main')),
    ]);
    await tester.pumpAndSettle();
    expect(find.textContaining('was feat/parent'), findsNothing);
  });

  testWidgets(
    'a worktree the snapshot does not know keeps its open-time facts',
    (tester) async {
      // A brand-new worktree, or one just removed: there is nothing to re-derive
      // from, so the sheet must degrade rather than blank itself.
      final repos = ValueNotifier(ReposState([repoWith(wt(insertions: 3))]));
      addTearDown(repos.dispose);
      await pumpSheet(tester, repos, worktreePath: '/wt/unknown');
      expect(find.text('+3'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a PR dropped from the snapshot is not shown from the stale open-time field',
    (tester) async {
      // Thread 1: when the snapshot KNOWS the worktree but its PR is now null
      // (closed and dropped), the re-derived status correctly shows no PR — so
      // the sheet must not keep painting the open-time PR. In particular the
      // "Open … on GitHub" link must be gone: it dereferences the live url, and
      // resurrecting it from the stale field is exactly what threw a null assert.
      const openPr = PullRequest(
        number: 7,
        url: 'https://example.test/7',
        state: 'OPEN',
        title: 'the pr',
        isDraft: false,
        checkRollup: 'none',
        unresolvedComments: 0,
        checks: [],
      );
      // The worktree in the snapshot has no PR (the `wt` helper leaves it null).
      final repos = ValueNotifier(ReposState([repoWith(wt(insertions: 3))]));
      addTearDown(repos.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<ReposState>(
          valueListenable: repos,
          builder: (context, value, _) => ProviderScope(
            overrides: [reposProvider.overrideWithValue(value)],
            child: MaterialApp(
              home: Scaffold(
                body: PrDetailBody(
                  // Open-time facts carry a live PR...
                  status: prStatus(pr: openPr, branch: 'feat/child'),
                  pr: openPr,
                  onRun: (_) {},
                  projectId: 'p1',
                  worktreePath: '/wt/child',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // ...but the snapshot says there is no PR, so the link is gone.
      expect(
        find.textContaining('on GitHub'),
        findsNothing,
        reason: 'a worktree with no live PR must not resurrect the stale one',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
