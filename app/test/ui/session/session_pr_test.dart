// Mobile PR surface: the session subtitle chip and the shared detail sheet it
// opens (direction B1).
//
// The *rules* (which fact is loudest, which remedy clears it) live in
// pr_signals_test.dart. These cover the mobile rendering: what the chip says,
// how the sheet is ordered, and that a picked prompt reaches the composer unsent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/session_pr_chip.dart';
import 'package:makit/ui/session/session_screen.dart';
import 'package:makit/ui/widgets/pr_actions.dart';
import 'package:makit/ui/widgets/pr_detail.dart';
import 'package:makit/ui/widgets/pr_signals.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();

  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

PrCheck _check(String name, String bucket, {String? workflow}) =>
    PrCheck(name: name, bucket: bucket, workflowName: workflow);

PullRequest _pr({
  int number = 42,
  String state = 'OPEN',
  bool isDraft = false,
  String rollup = 'pass',
  List<PrCheck> checks = const [],
  String? mergeable,
  int unresolved = 0,
  bool unresolvedUnknown = false,
  String? url,
  String? baseRefName,
  String? mergeStateStatus,
}) => PullRequest(
  number: number,
  url: url ?? 'https://github.com/o/r/pull/$number',
  state: state,
  title: 'Add the login screen',
  isDraft: isDraft,
  mergeable: mergeable,
  mergeStateStatus: mergeStateStatus,
  checks: checks,
  checkRollup: rollup,
  unresolvedComments: unresolved,
  unresolvedUnknown: unresolvedUnknown,
  baseRefName: baseRefName,
);

/// Pump the sheet's body directly — the modal route is exercised via the screen
/// test below. `showCta: true` mirrors what `showPrDetail(sheet: true)` passes.
Future<void> _pumpSheet(
  WidgetTester tester, {
  PullRequest? pr,
  int uncommitted = 0,
  int ahead = 0,
  void Function(PrRemedy remedy)? onRun,
  Map<String, Object?> overrides = const {},
  bool canInsertPrompt = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesControllerProvider.overrideWith(
          (ref) => PreferencesController(null, overrides),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: PrDetailBody(
            status: prStatus(
              pr: pr,
              branch: 'feat',
              uncommittedFiles: uncommitted,
              commitsAhead: ahead,
            ),
            pr: pr,
            showCta: true,
            canInsertPrompt: canInsertPrompt,
            onRun: onRun ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the detail sheet', () {
    testWidgets('names the PR and its title', (tester) async {
      await _pumpSheet(tester, pr: _pr());
      expect(find.text('#42'), findsOneWidget);
      expect(find.text('Add the login screen'), findsOneWidget);
    });

    testWidgets('opens on the decision: headline, then action, then detail', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'fail', unresolved: 3, checks: [_check('a', 'fail')]),
        ahead: 1,
      );
      // The loud fact is the headline. Three problems here, so the button offers
      // to take them all on at once; the individual ones are listed below it.
      expect(find.text('1 commit unpushed'), findsOneWidget);
      final headlineY = tester.getTopLeft(find.text('1 commit unpushed')).dy;
      final ctaY = tester.getTopLeft(find.text('Fix')).dy;
      final detailY = tester.getTopLeft(find.text('3 threads open')).dy;
      expect(headlineY, lessThan(ctaY));
      expect(ctaY, lessThan(detailY), reason: 'decision above detail');
    });

    testWidgets('lists each check with its human status word', (tester) async {
      await _pumpSheet(
        tester,
        pr: _pr(
          rollup: 'fail',
          checks: [
            _check('analyze', 'pass'),
            _check('test', 'fail', workflow: 'CI'),
            _check('golden', 'skipping'),
          ],
        ),
      );
      expect(find.text('CI / test'), findsOneWidget);
      expect(find.text('failed'), findsOneWidget);
      expect(find.text('analyze'), findsOneWidget);
      expect(find.text('passed'), findsOneWidget);
      expect(find.text('skipped'), findsOneWidget);
    });

    testWidgets('floats failing checks above passing ones', (tester) async {
      await _pumpSheet(
        tester,
        pr: _pr(
          rollup: 'fail',
          checks: [_check('a-passes', 'pass'), _check('z-fails', 'fail')],
        ),
      );
      final failY = tester.getTopLeft(find.text('z-fails')).dy;
      final passY = tester.getTopLeft(find.text('a-passes')).dy;
      expect(failY, lessThan(passY));
    });

    testWidgets('reports a conflicting merge state as an actionable fact', (
      tester,
    ) async {
      await _pumpSheet(tester, pr: _pr(mergeable: 'CONFLICTING'));
      // It is the loudest thing here, so it is the headline...
      expect(find.text('conflicts with the base'), findsOneWidget);
      // ...and the pinned action is what clears it.
      expect(find.text('Pull'), findsOneWidget);
    });

    testWidgets('gives every other actionable fact its own remedy button', (
      tester,
    ) async {
      // This is the trade B1 makes: the row is quiet, so the sheet is where the
      // secondary facts become actionable.
      PrRemedy? ran;
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'fail', unresolved: 2, checks: [_check('a', 'fail')]),
        ahead: 1,
        onRun: (r) => ran = r,
      );
      expect(find.text('1 commit unpushed'), findsOneWidget, reason: 'headline');
      expect(find.text('1 check failing'), findsOneWidget);
      expect(find.text('2 threads open'), findsOneWidget);
      expect(find.text('ALSO NEEDS YOU'), findsOneWidget);

      await tester.tap(find.text('Resolve threads'));
      await tester.pumpAndSettle();
      expect((ran as PromptRemedy).action, PrPromptAction.resolveComments);
    });

    testWidgets('separates facts that need you from facts that are just true', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        pr: _pr(
          rollup: 'fail',
          unresolved: 1,
          checks: [_check('a', 'fail'), _check('b', 'pending')],
        ),
      );
      expect(find.text('ALSO NEEDS YOU'), findsOneWidget);
      // A fact you cannot act on is still listed, just outside that group.
      expect(find.text('1 of 2 checks still running'), findsOneWidget);
    });

    testWidgets('pins one call to action, and says it will not send', (
      tester,
    ) async {
      await _pumpSheet(tester, uncommitted: 3);
      // Exactly one: the pinned button. The fact is the headline, so it does not
      // also appear as a list row with a duplicate button.
      expect(find.text('Commit & push'), findsOneWidget);
      expect(find.textContaining('never sends for you'), findsOneWidget);
    });

    testWidgets('a merged PR pins Wrap up and warns it runs server-side', (
      tester,
    ) async {
      PrRemedy? ran;
      await _pumpSheet(
        tester,
        pr: _pr(state: 'MERGED', baseRefName: 'main'),
        onRun: (r) => ran = r,
      );
      expect(find.text('Wrap up'), findsOneWidget);
      expect(find.textContaining('Asks first'), findsOneWidget);
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect((ran as DirectRemedy).op, PrDirectOp.wrapUp);
    });

    testWidgets('a draft pins Mark ready and says it runs server-side', (
      tester,
    ) async {
      PrRemedy? ran;
      await _pumpSheet(
        tester,
        pr: _pr(isDraft: true, rollup: 'pass'),
        onRun: (r) => ran = r,
      );
      expect(find.text('still a draft'), findsOneWidget, reason: 'headline');
      expect(find.text('Mark ready'), findsOneWidget);
      expect(find.textContaining('Runs on the server'), findsOneWidget);
      await tester.tap(find.text('Mark ready'));
      await tester.pumpAndSettle();
      expect((ran as DirectRemedy).op, PrDirectOp.markReady);
    });

    testWidgets('a moved base pins Update branch', (tester) async {
      PrRemedy? ran;
      await _pumpSheet(
        tester,
        pr: _pr(mergeStateStatus: 'BEHIND'),
        onRun: (r) => ran = r,
      );
      expect(find.text('the base branch moved on'), findsOneWidget);
      await tester.tap(find.text('Update branch'));
      await tester.pumpAndSettle();
      expect((ran as DirectRemedy).op, PrDirectOp.updateBranch);
    });

    testWidgets('a ready PR pins Squash & merge', (tester) async {
      PrRemedy? ran;
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'pass', mergeable: 'MERGEABLE'),
        onRun: (r) => ran = r,
      );
      expect(find.text('ready to merge'), findsOneWidget);
      await tester.tap(find.text('Squash & merge'));
      await tester.pumpAndSettle();
      expect((ran as DirectRemedy).op, PrDirectOp.squashMerge);
    });

    testWidgets('several problems pin one Fix that takes them all on', (
      tester,
    ) async {
      PrRemedy? ran;
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'fail', unresolved: 2, checks: [_check('a', 'fail')]),
        ahead: 1,
        onRun: (r) => ran = r,
      );
      expect(find.text('Fix'), findsOneWidget);
      // The specific remedies are still there, one row each.
      expect(find.text('Resolve threads'), findsOneWidget);
      await tester.tap(find.text('Fix'));
      await tester.pumpAndSettle();
      expect(ran, isA<MagicRemedy>());
    });

    testWidgets('a surface with no composer offers no prompt remedies', (
      tester,
    ) async {
      // The home list has nowhere to put a prompt. Rendering "Fix CI" there meant
      // the tap saved a preference, composed the text, closed the sheet and
      // dropped it — a dead button with no feedback.
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'fail', unresolved: 2, checks: [_check('a', 'fail')]),
        ahead: 1,
        canInsertPrompt: false,
      );
      expect(find.text('Fix CI'), findsNothing);
      expect(find.text('Resolve threads'), findsNothing);
      expect(find.text('Push'), findsNothing);
      // The facts themselves are still reported — only the dead buttons go.
      expect(find.text('2 threads open'), findsOneWidget);
    });

    testWidgets('a surface with no composer still offers the direct ops', (
      tester,
    ) async {
      // Tidying up needs no composer, so a merged PR is fully actionable there.
      PrRemedy? ran;
      await _pumpSheet(
        tester,
        pr: _pr(state: 'MERGED'),
        canInsertPrompt: false,
        onRun: (r) => ran = r,
      );
      expect(find.text('Wrap up'), findsOneWidget);
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect((ran as DirectRemedy).op, PrDirectOp.wrapUp);
    });

    testWidgets('pins nothing when there is nothing pressing', (tester) async {
      // An idle full-width button would be the loudest thing on a screen with
      // nothing to do.
      // `mergeable` is unreported here, so there is no merge to offer either.
      await _pumpSheet(tester, pr: _pr(rollup: 'pass'));
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('the session subtitle chip', () {
    const sessionId = 's1';

    Future<void> pumpScreen(
      WidgetTester tester, {
      required String? worktreePath,
      PullRequest? pr,
      int uncommitted = 0,
      bool primary = false,
      String branch = 'feat',
    }) async {
      final session = Session(
        id: sessionId,
        projectId: 'p1',
        agent: 'pi',
        title: 'Session',
        status: SessionStatus.idle,
        policy: ApprovalPolicy.askOnRisky,
        worktreePath: worktreePath,
      );
      final repo = RepoInfo(
        id: 'p1',
        name: 'repo',
        path: '/repo',
        pinned: false,
        lastActivityAt: 0,
        isGitRepo: true,
        defaultBranch: 'main',
        currentBranch: 'main',
        worktrees: [
          Worktree(
            id: 'w1',
            path: '/repo/wt',
            branch: branch,
            isPrimary: primary,
            insertions: 0,
            deletions: 0,
            filesChanged: 0,
            uncommittedFiles: uncommitted,
            sessionIds: const [sessionId],
            pr: pr,
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionControllerProvider.overrideWith(
              (ref) => ConnectionController(const _EmptyStorage()),
            ),
            projectsProvider.overrideWithValue(ProjectsState(const [])),
            reposProvider.overrideWithValue(ReposState([repo])),
            sessionsProvider.overrideWithValue(SessionsState([session])),
            chatItemsProvider(sessionId).overrideWithValue(const []),
            sessionMetaProvider(sessionId).overrideWithValue(null),
            sessionActionErrorProvider(sessionId).overrideWithValue(null),
            commandsProvider(sessionId).overrideWithValue(const []),
          ],
          child: const MaterialApp(home: SessionScreen(sessionId: sessionId)),
        ),
      );
      await tester.pump();
    }

    testWidgets('says the PR number and what it needs', (tester) async {
      await pumpScreen(
        tester,
        worktreePath: '/repo/wt',
        pr: _pr(rollup: 'fail', checks: [_check('a', 'fail')]),
      );
      expect(find.byType(SessionPrChip), findsOneWidget);
      // The old chip showed "#42 failed" — a verdict, with no next step.
      expect(find.text('#42 · 1 check failing'), findsOneWidget);
    });

    testWidgets('reports local work even with no PR at all', (tester) async {
      // The old chip only existed when a PR did, so a branch with three
      // uncommitted files said nothing on this screen.
      await pumpScreen(tester, worktreePath: '/repo/wt', uncommitted: 3);
      expect(find.text('3 files uncommitted'), findsOneWidget);
    });

    testWidgets('stays silent for a clean primary checkout', (tester) async {
      await pumpScreen(
        tester,
        worktreePath: '/repo/wt',
        primary: true,
        branch: 'main',
      );
      expect(find.byType(SessionPrChip), findsNothing);
    });

    testWidgets('shows nothing before the session has a worktree', (
      tester,
    ) async {
      await pumpScreen(tester, worktreePath: null, pr: _pr());
      expect(find.byType(SessionPrChip), findsNothing);
    });

    testWidgets('a picked prompt lands in the composer without sending', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        worktreePath: '/repo/wt',
        pr: _pr(rollup: 'fail', checks: [_check('a', 'fail')]),
      );
      await tester.tap(find.text('#42 · 1 check failing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix CI').last);
      await tester.pumpAndSettle();

      // The prompt is in the field for the user to review and send. Matching a
      // distinctive fragment: the composer soft-wraps the full prompt.
      expect(
        find.textContaining('CI checks on this pull request'),
        findsWidgets,
      );
      // The sheet is gone, so the composer is what the user is looking at.
      expect(find.byType(PrDetailBody), findsNothing);
    });
  });
}
