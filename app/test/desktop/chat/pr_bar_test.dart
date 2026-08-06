// The composer's next-step bar (direction B1): one sentence about the worktree,
// a `+n more` disclosure, and the one action that clears the loudest fact.
//
// The *rules* (which fact is loudest, which remedy clears it) are pinned in
// pr_signals_test.dart. These cover what the widget does with them: what is on
// screen, what tapping things runs, and the two endings a PR can have.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/pr_bar.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/ui/widgets/pr_actions.dart';
import 'package:makit/ui/widgets/pr_signals.dart';
import 'package:makit/ui/widgets/pr_tone.dart';
import 'package:makit/ui/widgets/wrap_up.dart';

PullRequest _pr({
  String state = 'OPEN',
  String rollup = 'pass',
  bool isDraft = false,
  List<PrCheck> checks = const [],
  int unresolvedComments = 0,
  bool stale = false,
  bool unresolvedUnknown = false,
  String? baseRefName,
  String? mergeStateStatus,
}) => PullRequest(
  number: 42,
  url: 'https://github.com/o/r/pull/42',
  state: state,
  title: 'A pull request title',
  isDraft: isDraft,
  mergeStateStatus: mergeStateStatus,
  checkRollup: rollup,
  checks: checks,
  unresolvedComments: unresolvedComments,
  stale: stale,
  unresolvedUnknown: unresolvedUnknown,
  baseRefName: baseRefName,
);

Widget _host(
  PreferencesController controller, {
  PullRequest? pr,
  String? branch = 'feat/x',
  int uncommittedFiles = 0,
  int commitsAhead = 0,
  int commitsBehind = 0,
  String? projectId = 'p1',
  String? worktreePath = '/wt/feat-x',
  required void Function(String) onInsert,
  List<PrDirectOp>? ran,
}) => ProviderScope(
  overrides: [
    preferencesControllerProvider.overrideWith((ref) => controller),
    // SPEC-38 T7.3: the executor is injected, so a test can watch a direct op
    // run (and complete) without a live connection.
    if (ran != null)
      prOpRunnerProvider.overrideWithValue((op, _) async {
        ran.add(op);
        return const PrOpOutcome('done');
      }),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: PrComposerBar(
        branch: branch,
        uncommittedFiles: uncommittedFiles,
        status: prStatus(
          pr: pr,
          branch: branch,
          uncommittedFiles: uncommittedFiles,
          commitsAhead: commitsAhead,
          commitsBehind: commitsBehind,
        ),
        pr: pr,
        projectId: projectId,
        worktreePath: worktreePath,
        onInsertPrompt: onInsert,
      ),
    ),
  ),
);

/// The bar renders its sentence as one rich Text; assert on the flattened runs.
String _sentence(WidgetTester tester) {
  final text = tester.widget<Text>(
    find
        .descendant(of: find.byType(PrComposerBar), matching: find.byType(Text))
        .first,
  );
  return text.textSpan!.toPlainText();
}

void main() {
  group('the sentence', () {
    testWidgets('names the PR and the loudest fact', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(
            rollup: 'fail',
            checks: const [
              PrCheck(name: 'analyze', bucket: 'fail'),
              PrCheck(name: 'test', bucket: 'fail'),
            ],
          ),
          onInsert: (_) {},
        ),
      );
      expect(_sentence(tester), contains('#42'));
      expect(_sentence(tester), contains('2 checks failing'));
    });

    testWidgets('names the branch when there is no PR', (tester) async {
      await tester.pumpWidget(
        _host(PreferencesController.ephemeral(), onInsert: (_) {}),
      );
      expect(_sentence(tester), contains('feat/x'));
    });

    testWidgets('reports only the loudest fact, not all of them', (
      tester,
    ) async {
      // This is the whole point of B1: the bar whispers. The other facts are a
      // count, not a wall of chips.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'fail', unresolvedComments: 3),
          uncommittedFiles: 2,
          commitsAhead: 1,
          onInsert: (_) {},
        ),
      );
      expect(_sentence(tester), contains('2 files uncommitted'));
      expect(_sentence(tester), isNot(contains('threads')));
      expect(_sentence(tester), isNot(contains('unpushed')));
    });
  });

  group('the +n more disclosure', () {
    testWidgets('counts the facts it is standing in for', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'fail', unresolvedComments: 3),
          uncommittedFiles: 2,
          commitsAhead: 1,
          onInsert: (_) {},
        ),
      );
      // uncommitted (loud) + behind? no + ahead + CI + threads = 3 others.
      expect(find.text('+3 more'), findsOneWidget);
    });

    testWidgets('is absent when there is nothing else to say', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'pass'),
          onInsert: (_) {},
        ),
      );
      expect(find.textContaining('more'), findsNothing);
    });

    testWidgets('opens the detail, which lists every fact with a remedy', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'fail', unresolvedComments: 3),
          commitsAhead: 1,
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('+2 more'));
      await tester.pumpAndSettle();
      // Facts the bar elided are now visible *and* actionable — the trade B1
      // makes for a quiet bar.
      expect(find.text('3 threads open'), findsOneWidget);
      expect(find.text('1 commit unpushed'), findsOneWidget);
      expect(find.text('Resolve threads'), findsOneWidget);
    });

    testWidgets('a remedy picked in the detail inserts its prompt', (
      tester,
    ) async {
      String? inserted;
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'fail', unresolvedComments: 3),
          commitsAhead: 1,
          onInsert: (p) => inserted = p,
        ),
      );
      await tester.tap(find.text('+2 more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Resolve threads'));
      await tester.pumpAndSettle();
      expect(inserted, PrPromptAction.resolveComments.defaultPrompt);
    });
  });

  group('the call to action', () {
    testWidgets('runs the loudest fact\'s remedy', (tester) async {
      String? inserted;
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          uncommittedFiles: 3,
          onInsert: (p) => inserted = p,
        ),
      );
      expect(find.text('Commit & push'), findsOneWidget);
      await tester.tap(find.text('Commit & push'));
      await tester.pumpAndSettle();
      expect(inserted, PrPromptAction.commitAndPush.defaultPrompt);
    });

    testWidgets('a Settings override replaces the built-in prompt', (
      tester,
    ) async {
      final controller = PreferencesController.ephemeral();
      await controller.set(prCommitPushPromptPreference, 'MY commit prompt');
      String? inserted;
      await tester.pumpWidget(
        _host(controller, uncommittedFiles: 1, onInsert: (p) => inserted = p),
      );
      await tester.tap(find.text('Commit & push'));
      await tester.pumpAndSettle();
      expect(inserted, 'MY commit prompt');
    });

    testWidgets('offers to create a PR when the branch has none', (
      tester,
    ) async {
      String? inserted;
      await tester.pumpWidget(
        _host(PreferencesController.ephemeral(), onInsert: (p) => inserted = p),
      );
      await tester.tap(find.text('Create PR'));
      await tester.pumpAndSettle();
      expect(inserted, PrPromptAction.createPr.defaultPrompt);
    });

    testWidgets('rests when nothing is pressing, and inserts nothing', (
      tester,
    ) async {
      // The old bar fell back to "whatever you picked last" — offering Pull with
      // nothing to pull. Resting is honest; the menu is still one tap away.
      String? inserted;
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'pass'),
          onInsert: (p) => inserted = p,
        ),
      );
      expect(find.text('Ask the agent'), findsOneWidget);
      await tester.tap(find.text('Ask the agent'));
      await tester.pumpAndSettle();
      expect(inserted, isNull, reason: 'idle opens the menu, it does not act');
      expect(find.text('ASK THE AGENT'), findsOneWidget);
    });
  });

  group('the menu', () {
    testWidgets('greys inapplicable prompts and says why', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'pass'),
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.byTooltip('PR actions'));
      await tester.pumpAndSettle();
      // Still listed — an absent action must never read as a missing feature.
      expect(find.text('Fix PR'), findsOneWidget);
      expect(find.text('the build is not failing'), findsOneWidget);
      final button = tester.widget<MenuItemButton>(
        find.ancestor(
          of: find.text('Fix PR'),
          matching: find.byType(MenuItemButton),
        ),
      );
      expect(button.onPressed, isNull, reason: 'listed but not runnable');
    });

    testWidgets('drops "Create PR" once a PR exists', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'pass'),
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.byTooltip('PR actions'));
      await tester.pumpAndSettle();
      expect(find.text('Create PR'), findsNothing);
    });
  });

  group('endings', () {
    testWidgets('a merged PR offers to wrap up, not to fix its history', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED', rollup: 'fail'),
          onInsert: (_) {},
        ),
      );
      expect(find.text('Wrap up'), findsOneWidget);
      expect(find.text('Fix CI'), findsNothing);
      expect(_sentence(tester), contains('merged'));
    });

    testWidgets('wrap up asks first, spelling out every step', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED', baseRefName: 'release/2.0'),
          branch: 'feat/x',
          uncommittedFiles: 2,
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Remove the worktree at /wt/feat-x'),
        findsOneWidget,
      );
      // It names the branch it will move, rather than saying "the base branch".
      expect(find.textContaining('Fast-forward release/2.0'), findsOneWidget);
      // And it warns about the work it is about to destroy.
      expect(find.textContaining('will be lost'), findsOneWidget);
    });

    testWidgets('cancelling the confirm does nothing', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED'),
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Fast-forward'), findsNothing);
    });

    testWidgets('a closed PR offers to discard the worktree', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'CLOSED'),
          onInsert: (_) {},
        ),
      );
      expect(find.text('Discard worktree'), findsOneWidget);
      expect(_sentence(tester), contains('closed without merging'));
    });
  });

  group('the non-destructive direct ops', () {
    testWidgets('a draft offers Mark ready', (tester) async {
      // That it runs *without* a confirm is `isDestructive`'s rule, pinned in
      // pr_signals_test.dart — asserting it here would mean standing up a fake
      // connection just to observe the absence of a dialog.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(isDraft: true, rollup: 'pass'),
          onInsert: (_) {},
        ),
      );
      expect(_sentence(tester), contains('still a draft'));
      expect(find.text('Mark ready'), findsOneWidget);
    });

    testWidgets('a moved base offers Update branch', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(mergeStateStatus: 'BEHIND'),
          onInsert: (_) {},
        ),
      );
      expect(_sentence(tester), contains('the base branch moved on'));
      expect(find.text('Update branch'), findsOneWidget);
    });

    testWidgets('the menu keeps a direct op the CTA is not showing', (
      tester,
    ) async {
      // Draft + red build: the button says Fix CI, but marking it ready is still
      // a legitimate thing to do, so the menu must not drop it.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(
            isDraft: true,
            rollup: 'fail',
            checks: const [PrCheck(name: 'a', bucket: 'fail')],
          ),
          onInsert: (_) {},
        ),
      );
      expect(find.text('Fix CI'), findsOneWidget, reason: 'the CTA');
      await tester.tap(find.byTooltip('PR actions'));
      await tester.pumpAndSettle();
      expect(find.text('DO NOW'), findsOneWidget);
      expect(find.text('Mark ready'), findsOneWidget);
    });
  });

  group('the confirms name what they actually do (SPEC-38 G1/G4)', () {
    testWidgets('wrap up names the branch it will delete', (tester) async {
      // wrapUpWorktree runs `git branch -D <branch>` (spec §6.1 step 3). The
      // dialog never said so: the step was guarded on an identity that is always
      // '#42' once a PR exists, so the line was dead code.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED', baseRefName: 'main'),
          branch: 'feat/x',
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Delete the local branch feat/x'),
        findsOneWidget,
      );
    });

    testWidgets('discard names the branch it will delete too', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'CLOSED'),
          branch: 'feat/x',
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Discard worktree'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Delete the local branch feat/x'),
        findsOneWidget,
      );
    });

    testWidgets('a detached worktree is not promised a branch deletion', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED'),
          branch: null,
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Delete the local branch'), findsNothing);
    });

    testWidgets('says sessions are archived, after the removal', (
      tester,
    ) async {
      // The server removes the worktree first and *archives* live sessions
      // (SPEC-29) rather than stopping them; the dialog claimed the reverse order
      // and the wrong verb.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED'),
          branch: 'feat/x',
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      // All four, in the order the server runs them — a single pair would let any
      // of the other three drift.
      final ys = [
        tester.getTopLeft(find.textContaining('Remove the worktree')).dy,
        tester.getTopLeft(find.textContaining('Archive the sessions')).dy,
        tester.getTopLeft(find.textContaining('Delete the local branch')).dy,
        tester.getTopLeft(find.textContaining('Fast-forward')).dy,
      ];
      expect(
        ys,
        orderedEquals(<Matcher>[
          lessThan(ys[1]),
          lessThan(ys[2]),
          lessThan(ys[3]),
          anything,
        ]),
      );
    });

    testWidgets('the data-loss warning does not depend on any label text', (
      tester,
    ) async {
      // It used to be inferred with `label.contains('uncommitted')`. Proving the
      // fix means driving the dialog from a status whose labels say nothing about
      // uncommitted work, while the count is passed structurally — the old
      // implementation could not have produced a warning here.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesControllerProvider.overrideWith(
              (ref) => PreferencesController.ephemeral(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showPrDirectConfirm(
                    context,
                    op: PrDirectOp.wrapUp,
                    pr: _pr(state: 'MERGED'),
                    worktreePath: '/wt/feat-x',
                    identity: '#42',
                    branch: 'feat/x',
                    uncommittedFiles: 2,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('2 files uncommitted here will be lost'),
        findsOneWidget,
      );
    });

    testWidgets('and it is absent when there is nothing to lose', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED'),
          branch: 'feat/x',
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect(find.textContaining('will be lost'), findsNothing);
    });
  });

  group('confirming on stale data (SPEC-38 L1)', () {
    // The app decides which destructive button to show from the last snapshot,
    // and the server does not re-check GitHub (L1). When that snapshot is
    // explicitly last-known — SPEC-32 shed the refresh to save quota — the
    // premise of the dialog ("this PR has merged") may simply be false, so the
    // dialog says so rather than asserting it.
    testWidgets('wrap up warns that the state could not be refreshed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED', stale: true),
          branch: 'feat/x',
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect(find.textContaining('could not be refreshed'), findsOneWidget);
    });

    testWidgets('discard warns too — it is the destructive one', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'CLOSED', stale: true),
          branch: 'feat/x',
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Discard worktree'));
      await tester.pumpAndSettle();
      expect(find.textContaining('could not be refreshed'), findsOneWidget);
    });

    testWidgets('fresh data gets no warning', (tester) async {
      // It has to stay rare, or it becomes noise people click past.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED'),
          branch: 'feat/x',
          onInsert: (_) {},
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect(find.textContaining('could not be refreshed'), findsNothing);
    });

    testWidgets('the warning does not block the action', (tester) async {
      // Refusing on stale data would reintroduce exactly the quota trap that L1's
      // proposed fix was rejected for: tidying up must stay possible.
      final ran = <PrDirectOp>[];
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED', stale: true),
          branch: 'feat/x',
          onInsert: (_) {},
          ran: ran,
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Wrap up'));
      await tester.pumpAndSettle();
      expect(ran, [PrDirectOp.wrapUp]);
    });
  });

  group('dispatch (SPEC-38 T7.3)', () {
    testWidgets('a non-confirming op runs straight away, with no dialog', (
      tester,
    ) async {
      final ran = <PrDirectOp>[];
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(isDraft: true, rollup: 'pass'),
          onInsert: (_) {},
          ran: ran,
        ),
      );
      await tester.tap(find.text('Mark ready'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsNothing, reason: 'no confirm');
      expect(ran, [PrDirectOp.markReady]);
    });

    testWidgets('a confirming op runs only after the confirm is accepted', (
      tester,
    ) async {
      final ran = <PrDirectOp>[];
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED'),
          branch: 'feat/x',
          onInsert: (_) {},
          ran: ran,
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect(ran, isEmpty, reason: 'not yet — the dialog is up');
      await tester.tap(find.widgetWithText(FilledButton, 'Wrap up'));
      await tester.pumpAndSettle();
      expect(ran, [PrDirectOp.wrapUp]);
    });

    testWidgets('a branch-deleting op is refused when the branch is unknown', (
      tester,
    ) async {
      // Wrap up and discard both end in `git branch -D`, and the server resolves
      // the branch itself. With none in the snapshot the confirm cannot name what
      // it will delete — it silently drops that step — and no `expectBranch`
      // travels with the command, so the guard that stops the wrong branch going
      // is switched off precisely when the app is least sure. Refuse instead.
      final ran = <PrDirectOp>[];
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED'),
          branch: null,
          onInsert: (_) {},
          ran: ran,
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      expect(ran, isEmpty, reason: 'nothing may be dispatched');
      expect(find.textContaining('which branch'), findsOneWidget);
    });

    testWidgets('cancelling runs nothing', (tester) async {
      final ran = <PrDirectOp>[];
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(state: 'MERGED'),
          branch: 'feat/x',
          onInsert: (_) {},
          ran: ran,
        ),
      );
      await tester.tap(find.text('Wrap up'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(ran, isEmpty);
    });
  });

  group('stale (SPEC-32)', () {
    testWidgets('keeps the number crisp and says the data is last-known', (
      tester,
    ) async {
      // The old bar dimmed the whole pill, hiding the one fact that never goes
      // stale: which PR this is.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'fail', stale: true),
          onInsert: (_) {},
        ),
      );
      expect(_sentence(tester), contains('#42'));
      expect(_sentence(tester), contains('last known'));
      expect(find.byTooltip(kStalePrTooltip), findsOneWidget);
      // "Crisp" is the point, not merely "present": spec §8 says only the
      // *derived* half dims. Asserting the text alone passed while the number
      // was dimmed along with everything else.
      expect(_spanAlpha(tester, '#42'), 1.0);
      expect(_spanAlpha(tester, 'CI failing'), lessThan(1.0));
    });

    testWidgets('a fresh PR says nothing about staleness', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'fail'),
          onInsert: (_) {},
        ),
      );
      expect(_sentence(tester), isNot(contains('last known')));
    });

    testWidgets('unresolvedUnknown hides the count instead of showing 0', (
      tester,
    ) async {
      // A positive count on purpose: with the helper's default of 0 the
      // assertion held even without the guard, so it pinned nothing.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(
            unresolvedComments: 3,
            unresolvedUnknown: true,
            rollup: 'pass',
          ),
          onInsert: (_) {},
        ),
      );
      expect(_sentence(tester), isNot(contains('thread')));
    });

    testWidgets('the same count is reported when it is known', (tester) async {
      // The control for the test above: without it, "hides the count" would also
      // pass on a bar that never shows thread counts at all.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(unresolvedComments: 3, rollup: 'pass'),
          onInsert: (_) {},
        ),
      );
      expect(_sentence(tester), contains('3 threads open'));
    });
  });

  group('the dot', () {
    testWidgets('shows a determinate arc while checks are in flight', (
      tester,
    ) async {
      // A rollup is a count, so the progress is known — an indeterminate
      // spinner would overstate the uncertainty.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(
            rollup: 'pending',
            checks: const [
              PrCheck(name: 'a', bucket: 'pass'),
              PrCheck(name: 'b', bucket: 'pending'),
            ],
          ),
          onInsert: (_) {},
        ),
      );
      final ring = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(ring.value, closeTo(0.5, 0.001));
    });

    testWidgets('is a plain dot when nothing is running', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(rollup: 'pass'),
          onInsert: (_) {},
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('is hollow for a branch named like a PR number', (
      tester,
    ) async {
      // `#42` is a legal branch name. Reading the display string classified such
      // a branch as having a PR and filled its dot in.
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          branch: '#42',
          commitsAhead: 1,
          onInsert: (_) {},
        ),
      );
      final dot = tester.widget<PrToneDot>(find.byType(PrToneDot));
      expect(dot.hollow, isTrue);
    });

    testWidgets('keeps the same footprint when the checks finish', (
      tester,
    ) async {
      // The bar's width is not negotiable and it must not twitch as CI churns:
      // the arc and the plain dot have different diameters, so the disc has to
      // sit inside the arc's box rather than shrink it.
      await tester.pumpWidget(
        const MaterialApp(
          home: Row(
            children: [
              PrToneDot(tone: PrTone.attention, progress: 0.5),
              PrToneDot(tone: PrTone.attention),
            ],
          ),
        ),
      );
      final sizes = tester
          .widgetList<PrToneDot>(find.byType(PrToneDot))
          .map((w) => tester.getSize(find.byWidget(w)))
          .toList();
      expect(sizes[1], sizes[0]);
    });
  });
}

/// The alpha of the sentence span carrying exactly [text].
///
/// Reads the style rather than the string: "the number stays crisp" is a claim
/// about how it is painted, and a test that only looks at the text passes while
/// it is dimmed.
double _spanAlpha(WidgetTester tester, String text) {
  final root = tester
      .widget<Text>(
        find
            .descendant(
              of: find.byType(PrComposerBar),
              matching: find.byType(Text),
            )
            .first,
      )
      .textSpan!;
  double? alpha;
  root.visitChildren((span) {
    if (span is TextSpan && span.text == text) {
      alpha = span.style?.color?.a;
      return false;
    }
    return true;
  });
  if (alpha == null) fail('no span said "$text" in: ${root.toPlainText()}');
  return alpha!;
}
