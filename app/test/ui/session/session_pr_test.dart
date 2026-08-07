// Mobile PR surface: the session subtitle chip and the shared detail sheet it
// opens (direction B1).
//
// The *rules* (which fact is loudest, which remedy clears it) live in
// pr_signals_test.dart. These cover the mobile rendering: what the chip says,
// how the sheet is ordered, and that a picked prompt reaches the composer unsent.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:makit/app/theme.dart';
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
import 'package:makit/ui/widgets/pr_tone.dart';

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
  bool canInsertPrompt = true,
  bool expandDetail = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesControllerProvider.overrideWith(
          (ref) => PreferencesController(null, const {}),
        ),
      ],
      child: MaterialApp(
        theme: makitDarkTheme,
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
  // The sheet's detail is collapsed by default (SPEC-38 D15 / mockup §6). These
  // tests are about what the detail *says*, so open it once here; the collapsing
  // itself is covered by its own tests below.
  //
  // Asserted, not probed: a soft `isNotEmpty` check would let a regression that
  // deletes the disclosure pass every positional test in this file, because the
  // detail would then already be on screen in the right order.
  if (expandDetail) {
    expect(
      find.text('Detail'),
      findsOneWidget,
      reason: 'the sheet must collapse its detail',
    );
    await tester.tap(find.text('Detail'));
    await tester.pumpAndSettle();
  }
}

/// The same body as the desktop dialog renders it: no pinned CTA, so no
/// disclosure and the full fact list.
Future<void> _pumpDialogBody(
  WidgetTester tester, {
  PullRequest? pr,
  int uncommitted = 0,
  int ahead = 0,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesControllerProvider.overrideWith(
          (ref) => PreferencesController(null, const {}),
        ),
      ],
      child: MaterialApp(
        theme: makitDarkTheme,
        home: Scaffold(
          body: PrDetailBody(
            status: prStatus(
              pr: pr,
              branch: 'feat',
              uncommittedFiles: uncommitted,
              commitsAhead: ahead,
            ),
            pr: pr,
            onRun: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A url_launcher that resolves with [succeed] rather than throwing.
///
/// The distinction matters: with no plugin registered `launchUrl` throws, which
/// the `catch` already handled. A registered launcher that simply *declines*
/// returns false, and that path needs its own fake to reach.
class _DecliningUrlLauncher extends UrlLauncherPlatform {
  _DecliningUrlLauncher(this.succeed);

  final bool succeed;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async => succeed;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async => succeed;
}

/// Install [_DecliningUrlLauncher]; returns the teardown that puts the real one
/// back.
void Function() _stubUrlLauncher({required bool succeed}) {
  final previous = UrlLauncherPlatform.instance;
  UrlLauncherPlatform.instance = _DecliningUrlLauncher(succeed);
  return () => UrlLauncherPlatform.instance = previous;
}

void main() {
  group('the detail sheet', () {
    testWidgets('names the PR and its title', (tester) async {
      await _pumpSheet(tester, pr: _pr());
      expect(find.text('#42'), findsOneWidget);
      expect(find.text('Add the login screen'), findsOneWidget);
    });

    testWidgets('the pinned CTA paints its icon and label the same colour', (
      tester,
    ) async {
      // These were computed separately, and drifted: the label moved to
      // `onPrToneFill` while the icon kept `cs.surface`, so on the amber fill —
      // where `onPrToneFill` picks the dark ink — the icon went near-white on
      // amber and effectively disappeared.
      //
      // A draft: its CTA is the direct `Mark ready`, which is the filled register
      // and the amber tone.
      await _pumpSheet(tester, pr: _pr(isDraft: true));
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      final fg = button.style?.foregroundColor?.resolve(<WidgetState>{});
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(Icon),
        ),
      );
      expect(fg, isNotNull);
      expect(icon.color, fg, reason: 'the icon must match the label');
    });

    testWidgets('reports a PR url the platform declines to open', (
      tester,
    ) async {
      // `launchUrl` does not always throw: with no handler registered for the
      // scheme it returns false. Ignoring the result left the tap doing nothing
      // at all, which reads as a dead button.
      final saved = _stubUrlLauncher(succeed: false);
      addTearDown(saved);
      await _pumpSheet(tester, pr: _pr());

      await tester.tap(find.text('Open #42 on GitHub'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Could not open the PR'), findsOneWidget);
    });

    testWidgets('reports a PR url it cannot open instead of throwing', (
      tester,
    ) async {
      // `Uri.tryParse` rejects this outright; a real device can also refuse a
      // perfectly good URL with no handler. Either way the tap must not escape
      // as an unhandled framework error.
      await _pumpSheet(tester, pr: _pr(url: 'http://['));

      await tester.tap(find.text('Open #42 on GitHub'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Could not open the PR'), findsOneWidget);
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
      // `.first` is the pinned CTA: the magic remedy and the CI prompt share the
      // verb "Fix" (SPEC-38 §8 D12), so on a sheet that lists a failing build
      // both are on screen and the pinned one comes first in the tree.
      final ctaY = tester.getTopLeft(find.text('Fix').first).dy;
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
      expect(
        find.text('1 commit unpushed'),
        findsOneWidget,
        reason: 'headline',
      );
      expect(find.text('1 check failing'), findsOneWidget);
      expect(find.text('2 threads open'), findsOneWidget);
      expect(find.text('ALSO NEEDS YOU'), findsOneWidget);

      await tester.tap(find.text('Resolve'));
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
      // One fact, no checks: there is nothing left to disclose, so this state
      // renders no `Detail` row at all.
      await _pumpSheet(tester, uncommitted: 3, expandDetail: false);
      expect(
        find.text('Detail'),
        findsNothing,
        reason: 'nothing elided, nothing to hide',
      );
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
      // Two of them: the pinned button that composes all three, and the failing
      // build's own row remedy. They share the verb by decision (SPEC-38 §8 D12)
      // — the pinned one is the wide button at the top.
      expect(find.text('Fix'), findsNWidgets(2));
      // The specific remedies are still there, one row each.
      expect(find.text('Resolve'), findsOneWidget);
      await tester.tap(find.text('Fix').first);
      await tester.pumpAndSettle();
      expect(ran, isA<MagicRemedy>());
    });

    testWidgets('the merged sheet groups the residue, not the ending', (
      tester,
    ) async {
      // The sheet skips the loud fact before grouping (its headline already said
      // it), and that skip used to shift the whole list: `worktree still here`
      // landed under LANDED and vanished from LEFT BEHIND.
      await _pumpSheet(
        tester,
        pr: _pr(state: 'MERGED', rollup: 'pass', checks: [_check('a', 'pass')]),
        uncommitted: 2,
      );
      expect(find.text('LEFT BEHIND'), findsOneWidget);
      expect(find.text('worktree still here'), findsOneWidget);
      expect(find.text('2 files uncommitted'), findsOneWidget);
      final leftBehindY = tester.getTopLeft(find.text('LEFT BEHIND')).dy;
      expect(
        tester.getTopLeft(find.text('worktree still here')).dy,
        greaterThan(leftBehindY),
        reason: 'the residue belongs under LEFT BEHIND',
      );
      // The headline is the ending, so the groups must not say it a second time.
      expect(
        find.text('merged'),
        findsOneWidget,
        reason: 'the hero, and only the hero',
      );
      expect(find.text('LANDED'), findsNothing);
    });

    testWidgets('the pinned Discard is the muted error fill, like desktop', (
      tester,
    ) async {
      // Both CTAs paint the same op; the mobile one kept the CI red after the
      // desktop one moved to the error container, so "discard" out-shouted a
      // failing build on one surface and not the other.
      await _pumpSheet(tester, pr: _pr(state: 'CLOSED'));
      final cs = makitDarkTheme.colorScheme;
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Discard worktree'),
      );
      expect(
        button.style?.backgroundColor?.resolve({}),
        prDirectCtaFill(cs, PrTone.blocking, destructive: true).bg,
      );
    });

    testWidgets('the disclosure caret reports its own state', (tester) async {
      // A custom `trailing` replaces the one ExpansionTile would have rotated, so
      // without an explicit rotation the open row and the closed row look
      // identical and the control says nothing about itself.
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'fail', unresolved: 3, checks: [_check('a', 'fail')]),
        ahead: 1,
        expandDetail: false,
      );
      double turns() =>
          tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns;
      expect(turns(), 0, reason: 'closed');
      await tester.tap(find.text('Detail'));
      await tester.pumpAndSettle();
      expect(turns(), 0.5, reason: 'open');
    });

    testWidgets('the closed disclosure peeks at the build behind it', (
      tester,
    ) async {
      // The whole point of the collapsed row is to say what is behind it, so the
      // count carries the verdict (mockup §6 draws it in the failing red).
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'fail', checks: [_check('a', 'fail')]),
        ahead: 1,
        expandDetail: false,
      );
      expect(
        tester.widget<Text>(find.text('1 check')).style?.color,
        prToneTextColor(makitDarkTheme.colorScheme, PrTone.blocking),
      );
    });

    testWidgets('a green build leaves the disclosure count neutral', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'pass', checks: [_check('a', 'pass')]),
        ahead: 1,
        expandDetail: false,
      );
      expect(
        tester.widget<Text>(find.text('1 check')).style?.color,
        makitDarkTheme.colorScheme.outline,
      );
    });

    testWidgets('a surface with no composer offers no prompt remedies', (
      tester,
    ) async {
      // The home list has nowhere to put a prompt. Rendering "Fix" there meant
      // the tap saved a preference, composed the text, closed the sheet and
      // dropped it — a dead button with no feedback.
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'fail', unresolved: 2, checks: [_check('a', 'fail')]),
        ahead: 1,
        canInsertPrompt: false,
      );
      expect(find.text('Fix'), findsNothing);
      expect(find.text('Resolve'), findsNothing);
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

  group('the detail layer, desktop dialog', () {
    testWidgets('says "Needs you" — nothing precedes it here', (tester) async {
      // The sheet's headline already states the loud fact, so its list is what
      // the headline left out and "Also" is true. The dialog lists everything.
      await _pumpDialogBody(
        tester,
        pr: _pr(rollup: 'fail', checks: [_check('a', 'fail')]),
        ahead: 1,
      );
      expect(find.text('NEEDS YOU'), findsOneWidget);
      expect(find.text('ALSO NEEDS YOU'), findsNothing);
      // ...and the loud fact is in the list, which is why "Also" would be wrong.
      expect(find.text('1 commit unpushed'), findsOneWidget);
    });

    testWidgets('an ended PR reads as a brief, not a check list', (
      tester,
    ) async {
      await _pumpDialogBody(
        tester,
        pr: _pr(
          state: 'MERGED',
          rollup: 'pass',
          checks: [_check('a', 'pass'), _check('b', 'pass')],
        ),
        uncommitted: 2,
      );
      // What landed, and what it left behind (mockup §4).
      expect(find.text('LANDED'), findsOneWidget);
      expect(find.text('LEFT BEHIND'), findsOneWidget);
      expect(find.text('merged'), findsOneWidget);
      expect(find.text('2 checks passed'), findsOneWidget);
      expect(find.text('worktree still here'), findsOneWidget);
      // The build is history: no per-check rows, and no "2 checks" group header.
      expect(find.text('2 checks'), findsNothing);
      expect(find.byType(PrCheckRow), findsNothing);
    });

    testWidgets('a fact row writes its severity, not only its glyph', (
      tester,
    ) async {
      // Every label used to print in the surface ink, so `2 checks failing` read
      // at the same weight as `3 threads open` and the only red was a 15px glyph.
      await _pumpDialogBody(
        tester,
        pr: _pr(rollup: 'fail', unresolved: 3, checks: [_check('a', 'fail')]),
        ahead: 1,
      );
      final cs = makitDarkTheme.colorScheme;
      Color? colorOf(String label) =>
          tester.widget<Text>(find.text(label)).style?.color;
      expect(colorOf('1 check failing'), prToneTextColor(cs, PrTone.blocking));
      expect(colorOf('3 threads open'), prToneTextColor(cs, PrTone.attention));
      expect(
        colorOf('1 commit unpushed'),
        prToneTextColor(cs, PrTone.attention),
      );
    });

    testWidgets('a quiet fact keeps the surface ink', (tester) async {
      // Context, not severity. A draft's build is the sharpest case: it is muted
      // by §5 precisely because the PR is not up for review, so the row must not
      // write it in red either.
      await _pumpDialogBody(
        tester,
        pr: _pr(isDraft: true, rollup: 'fail', checks: [_check('a', 'fail')]),
      );
      expect(
        tester.widget<Text>(find.text('1 check failing')).style?.color,
        makitDarkTheme.textTheme.bodyMedium?.color,
        reason: 'the body ink, not the failing red',
      );
    });

    testWidgets('a shed check list says why it is empty', (tester) async {
      // The rollup is on screen claiming a build result; with no rows and no note
      // that reads as the app having lost them (SPEC-32 sheds the per-check
      // lookup to stay inside GitHub's quota).
      await _pumpDialogBody(tester, pr: _pr(rollup: 'fail'));
      expect(find.text('CI failing'), findsOneWidget);
      expect(find.byType(PrCheckRow), findsNothing);
      expect(find.text(kShedChecksNote), findsOneWidget);
    });

    testWidgets('a PR with no CI at all says nothing about checks', (
      tester,
    ) async {
      // `checkRollup: none` is not a shed lookup — there is genuinely no build to
      // report, and explaining an absence nobody noticed is noise.
      await _pumpDialogBody(tester, pr: _pr(rollup: 'none'), ahead: 1);
      expect(find.text(kShedChecksNote), findsNothing);
    });

    testWidgets('a listed check list carries no such note', (tester) async {
      await _pumpDialogBody(
        tester,
        pr: _pr(rollup: 'fail', checks: [_check('a', 'fail')]),
      );
      expect(find.byType(PrCheckRow), findsOneWidget);
      expect(find.text(kShedChecksNote), findsNothing);
    });

    testWidgets('a live PR still lists every check', (tester) async {
      await _pumpDialogBody(
        tester,
        pr: _pr(rollup: 'fail', checks: [_check('a', 'fail')]),
      );
      expect(find.byType(PrCheckRow), findsOneWidget);
    });
  });

  group('the detail sheet, collapsed', () {
    testWidgets('opens on the decision: the detail is behind a disclosure', (
      tester,
    ) async {
      await _pumpSheet(
        tester,
        pr: _pr(rollup: 'fail', unresolved: 3, checks: [_check('a', 'fail')]),
        ahead: 1,
        expandDetail: false,
      );
      // The headline and the button are there...
      expect(find.text('1 commit unpushed'), findsOneWidget);
      expect(find.text('Fix'), findsOneWidget);
      // ...and the count says what is behind the door, so it is not a blind one.
      expect(find.text('Detail'), findsOneWidget);
      expect(find.text('1 check'), findsOneWidget);
      // But nothing else is on screen yet.
      expect(find.text('3 threads open'), findsNothing);
      expect(find.byType(PrCheckRow), findsNothing);

      await tester.tap(find.text('Detail'));
      await tester.pumpAndSettle();
      expect(find.text('3 threads open'), findsOneWidget);
      expect(find.byType(PrCheckRow), findsOneWidget);
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
      await tester.tap(find.text('Fix').last);
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
