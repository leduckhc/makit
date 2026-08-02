// Mobile PR surface (SPEC-23): the session subtitle chip and the shared PR
// bottom sheet it opens.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/ui/home/repo_chips.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/session_pr_chip.dart';
import 'package:makit/ui/session/session_screen.dart';
import 'package:makit/ui/widgets/pr_actions.dart';
import 'package:makit/ui/widgets/pr_sheet.dart';

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
}) => PullRequest(
  number: number,
  url: url ?? 'https://github.com/o/r/pull/$number',
  state: state,
  title: 'Add the login screen',
  isDraft: isDraft,
  mergeable: mergeable,
  checks: checks,
  checkRollup: rollup,
  unresolvedComments: unresolved,
  unresolvedUnknown: unresolvedUnknown,
);

/// Pumps the sheet's body directly — the modal route itself is exercised by the
/// chip test below.
Future<void> _pumpSheet(
  WidgetTester tester,
  PullRequest pr, {
  void Function(String prompt)? onInsertPrompt,
  Map<String, Object?> overrides = const {},
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
          body: PrSheetBody(pr: pr, onInsertPrompt: onInsertPrompt),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('PR sheet', () {
    testWidgets('names the PR and its title', (tester) async {
      await _pumpSheet(tester, _pr());

      expect(find.text('PR #42'), findsOneWidget);
      expect(find.text('Add the login screen'), findsOneWidget);
    });

    testWidgets('lists each check with its human status word', (tester) async {
      await _pumpSheet(
        tester,
        _pr(
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
        _pr(
          rollup: 'fail',
          checks: [_check('a-passes', 'pass'), _check('z-fails', 'fail')],
        ),
      );

      final failY = tester.getTopLeft(find.text('z-fails')).dy;
      final passY = tester.getTopLeft(find.text('a-passes')).dy;
      expect(failY, lessThan(passY));
    });

    testWidgets('reports a conflicting merge state', (tester) async {
      await _pumpSheet(tester, _pr(mergeable: 'CONFLICTING'));

      expect(find.textContaining('Conflicts'), findsOneWidget);
    });

    testWidgets('shows unresolved review comments when measured', (
      tester,
    ) async {
      await _pumpSheet(tester, _pr(unresolved: 3));
      expect(find.textContaining('3 unresolved'), findsOneWidget);
    });

    testWidgets('hides the comment count when it is unknown', (tester) async {
      // Non-zero on purpose: with a zero count the sheet would hide the line
      // because it is zero, and the test would pass even if unresolvedUnknown
      // were ignored entirely.
      await _pumpSheet(tester, _pr(unresolved: 3, unresolvedUnknown: true));
      expect(find.textContaining('unresolved'), findsNothing);
    });

    testWidgets('reports a PR url it cannot open instead of throwing', (
      tester,
    ) async {
      // `Uri.tryParse` rejects this outright; a real device can also refuse a
      // perfectly good URL with no handler. Either way the tap must not escape
      // as an unhandled framework error.
      await _pumpSheet(tester, _pr(url: 'http://['));

      await tester.tap(find.text('Open on GitHub'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Could not open the PR'), findsOneWidget);
    });

    testWidgets('marks a draft PR', (tester) async {
      await _pumpSheet(tester, _pr(isDraft: true));
      expect(find.text('draft'), findsOneWidget);
    });
  });

  group('PR actions in the sheet', () {
    testWidgets('offers them only when a composer can receive the prompt', (
      tester,
    ) async {
      await _pumpSheet(tester, _pr());
      expect(find.text('Fix PR'), findsNothing);

      await _pumpSheet(tester, _pr(), onInsertPrompt: (_) {});
      expect(find.text('Fix PR'), findsOneWidget);
      expect(find.text('Push'), findsOneWidget);
      // The sheet only opens for an existing PR, so creating one is not on offer
      // here — desktop drops it from the menu for the same reason.
      expect(find.text('Create PR'), findsNothing);
    });

    testWidgets('hands the built-in prompt to the composer', (tester) async {
      final inserted = <String>[];
      await _pumpSheet(tester, _pr(), onInsertPrompt: inserted.add);

      await tester.tap(find.text('Fix PR'));
      await tester.pumpAndSettle();

      expect(inserted, [PrPromptAction.fixPr.defaultPrompt]);
    });

    testWidgets('prefers a prompt override from settings', (tester) async {
      final inserted = <String>[];
      await _pumpSheet(
        tester,
        _pr(),
        onInsertPrompt: inserted.add,
        overrides: {prFixPromptPreference.id: 'my own fix prompt'},
      );

      await tester.tap(find.text('Fix PR'));
      await tester.pumpAndSettle();

      expect(inserted, ['my own fix prompt']);
    });
  });

  group('session PR chip', () {
    Future<void> pumpChip(WidgetTester tester, PullRequest pr) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: SessionPrChip(pr: pr)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('summarises the PR number and CI verdict', (tester) async {
      await pumpChip(tester, _pr(rollup: 'fail'));

      expect(find.text('#42'), findsOneWidget);
      expect(find.text('failed'), findsOneWidget);
    });

    testWidgets('omits the verdict when there are no checks', (tester) async {
      await pumpChip(tester, _pr(rollup: 'none'));

      expect(find.text('#42'), findsOneWidget);
      expect(find.text('none'), findsNothing);
    });

    testWidgets('is a touch-sized target', (tester) async {
      await pumpChip(tester, _pr());

      // The chip is the only route into the PR sheet from a session, so it has
      // to be hittable: it used to be 19px tall against the app's 44pt floor.
      final ink = find.descendant(
        of: find.byType(SessionPrChip),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(ink.first).height, greaterThanOrEqualTo(44));
    });

    testWidgets('opens the PR sheet when tapped', (tester) async {
      await pumpChip(tester, _pr(checks: [_check('test', 'pass')]));

      await tester.tap(find.text('#42'));
      await tester.pumpAndSettle();

      // The sheet carries the PR title, which the chip itself never shows.
      expect(find.text('Add the login screen'), findsOneWidget);
    });
  });

  group('home worktree PR pill', () {
    testWidgets('opens the same PR sheet when tapped', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(child: PrPill(pr: _pr())),
            ),
          ),
        ),
      );

      await tester.tap(find.text('PR #42'));
      await tester.pumpAndSettle();

      expect(find.byType(PrSheetBody), findsOneWidget);
      expect(find.text('Add the login screen'), findsOneWidget);
    });
  });

  group('session screen PR indicator', () {
    const sessionId = 's1';

    Future<void> pumpScreen(
      WidgetTester tester, {
      required String? worktreePath,
      PullRequest? pr,
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
            branch: 'feat',
            isPrimary: false,
            insertions: 0,
            deletions: 0,
            filesChanged: 0,
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

    testWidgets('shows the chip for the session worktree PR', (tester) async {
      await pumpScreen(tester, worktreePath: '/repo/wt', pr: _pr());

      expect(find.byType(SessionPrChip), findsOneWidget);
      expect(find.text('#42'), findsOneWidget);
    });

    testWidgets('shows no chip when the worktree has no PR', (tester) async {
      await pumpScreen(tester, worktreePath: '/repo/wt');

      expect(find.byType(SessionPrChip), findsNothing);
    });

    testWidgets('shows no chip before the session has a worktree', (
      tester,
    ) async {
      await pumpScreen(tester, worktreePath: null, pr: _pr());

      expect(find.byType(SessionPrChip), findsNothing);
    });

    testWidgets('a PR action lands in the composer without sending', (
      tester,
    ) async {
      await pumpScreen(tester, worktreePath: '/repo/wt', pr: _pr());

      await tester.tap(find.text('#42'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fix PR'));
      await tester.pumpAndSettle();

      // The prompt is in the field, for the user to review and send. Matching on
      // a distinctive fragment: the composer soft-wraps the full prompt.
      expect(
        find.textContaining('CI checks on this pull request'),
        findsWidgets,
      );
      // The sheet is gone, so the composer is what the user is looking at.
      expect(find.byType(PrSheetBody), findsNothing);
    });
  });
}
