import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/chat/pr_actions.dart';
import 'package:makit/desktop/chat/pr_bar.dart';
import 'package:makit/desktop/settings/prefs/preference_entries.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
import 'package:makit/desktop/settings/prefs/preferences_providers.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/widgets/pr_state_style.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../support/svg_asset_finder.dart';

Widget _host(
  PreferencesController controller, {
  PullRequest? pr,
  int uncommittedFiles = 0,
  int commitsAhead = 0,
  int commitsBehind = 0,
  required void Function(String) onInsert,
}) {
  return ProviderScope(
    overrides: [
      preferencesControllerProvider.overrideWith((ref) => controller),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: PrComposerBar(
          pr: pr,
          uncommittedFiles: uncommittedFiles,
          commitsAhead: commitsAhead,
          commitsBehind: commitsBehind,
          onInsertPrompt: onInsert,
        ),
      ),
    ),
  );
}

PullRequest _pr({
  String state = 'OPEN',
  String rollup = 'pass',
  bool isDraft = false,
  List<PrCheck> checks = const [],
  int unresolvedComments = 0,
  bool stale = false,
  bool unresolvedUnknown = false,
}) => PullRequest(
  number: 42,
  url: 'https://github.com/o/r/pull/42',
  state: state,
  title: 't',
  isDraft: isDraft,
  checkRollup: rollup,
  checks: checks,
  unresolvedComments: unresolvedComments,
  stale: stale,
  unresolvedUnknown: unresolvedUnknown,
);

/// The opacity a stale pill is drawn at, so the two-way test can assert the
/// dimmed value without duplicating the production constant.
double? _pillOpacity(WidgetTester tester) {
  final opacities = find.ancestor(
    of: find.text('PR #42'),
    matching: find.byType(Opacity),
  );
  if (opacities.evaluate().isEmpty) return null;
  return tester.widget<Opacity>(opacities.first).opacity;
}

void main() {
  testWidgets('actions button main segment inserts the default prompt', (
    tester,
  ) async {
    String? inserted;
    await tester.pumpWidget(
      _host(PreferencesController.ephemeral(), onInsert: (p) => inserted = p),
    );

    // Default last-action is Create PR; tapping its label runs it.
    await tester.tap(find.text('Create PR'));
    await tester.pumpAndSettle();
    expect(inserted, PrPromptAction.createPr.defaultPrompt);
  });

  testWidgets('a Settings override replaces the built-in prompt', (
    tester,
  ) async {
    final controller = PreferencesController.ephemeral();
    await controller.set(prCreatePromptPreference, 'MY custom create prompt');

    String? inserted;
    await tester.pumpWidget(_host(controller, onInsert: (p) => inserted = p));

    await tester.tap(find.text('Create PR'));
    await tester.pumpAndSettle();
    expect(inserted, 'MY custom create prompt');
  });

  testWidgets('picking a menu action inserts it and becomes the new main', (
    tester,
  ) async {
    final controller = PreferencesController.ephemeral();
    String? inserted;
    await tester.pumpWidget(_host(controller, onInsert: (p) => inserted = p));

    // Open the menu via the caret and pick "Fix PR".
    await tester.tap(find.byTooltip('PR actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fix PR').last);
    await tester.pumpAndSettle();

    expect(inserted, PrPromptAction.fixPr.defaultPrompt);
    expect(controller.get(lastPrActionPreference), 'fixPr');
    // The main segment now repeats Fix PR.
    expect(find.text('Fix PR'), findsOneWidget);
  });

  testWidgets('no PR → no pill, but the actions button still shows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(PreferencesController.ephemeral(), pr: null, onInsert: (_) {}),
    );
    expect(find.textContaining('PR #'), findsNothing);
    expect(find.text('Create PR'), findsOneWidget);
  });

  testWidgets('an existing PR hides "Create PR" from the menu', (tester) async {
    await tester.pumpWidget(
      _host(PreferencesController.ephemeral(), pr: _pr(), onInsert: (_) {}),
    );
    // Default main segment is the first non-create action (Fix PR).
    expect(find.text('Create PR'), findsNothing);
    await tester.tap(find.byTooltip('PR actions'));
    await tester.pumpAndSettle();
    expect(find.text('Create PR'), findsNothing);
    expect(find.text('Fix PR'), findsWidgets);
    expect(find.text('Resolve comments'), findsWidgets);
    expect(find.text('Commit and push'), findsWidgets);
  });

  testWidgets('a single chip shows; uncommitted outranks unresolved', (
    tester,
  ) async {
    String? inserted;
    await tester.pumpWidget(
      _host(
        PreferencesController.ephemeral(),
        pr: _pr(unresolvedComments: 3),
        uncommittedFiles: 2,
        onInsert: (p) => inserted = p,
      ),
    );
    // Only the top-priority chip renders — not a wall of competing hints.
    expect(find.text('2 uncommitted files'), findsOneWidget);
    expect(find.text('3 unresolved comments'), findsNothing);
    await tester.tap(find.text('Commit and push'));
    await tester.pumpAndSettle();
    expect(inserted, PrPromptAction.commitAndPush.defaultPrompt);
  });

  testWidgets('commits ahead (no uncommitted) → chip + default "Push"', (
    tester,
  ) async {
    String? inserted;
    await tester.pumpWidget(
      _host(
        PreferencesController.ephemeral(),
        pr: _pr(unresolvedComments: 2),
        commitsAhead: 3,
        onInsert: (p) => inserted = p,
      ),
    );
    // Unpushed commits outrank unresolved comments.
    expect(find.text('3 commits ahead'), findsOneWidget);
    expect(find.text('2 unresolved comments'), findsNothing);
    await tester.tap(find.text('Push'));
    await tester.pumpAndSettle();
    expect(inserted, PrPromptAction.push.defaultPrompt);
  });

  testWidgets('failing CI (nothing local) → chip + default "Fix PR"', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        PreferencesController.ephemeral(),
        pr: _pr(rollup: 'fail', unresolvedComments: 1),
        onInsert: (_) {},
      ),
    );
    // Failing CI outranks unresolved comments.
    expect(find.text('CI failing'), findsOneWidget);
    expect(find.text('1 unresolved comment'), findsNothing);
    expect(find.text('Fix PR'), findsOneWidget);
  });

  testWidgets('unresolved comments (nothing else) → default "Resolve"', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        PreferencesController.ephemeral(),
        pr: _pr(unresolvedComments: 1),
        onInsert: (_) {},
      ),
    );
    expect(find.text('1 unresolved comment'), findsOneWidget);
    // Main segment repeats the suggested default.
    expect(find.text('Resolve comments'), findsOneWidget);
  });

  testWidgets('with an open PR the pill renders its number', (tester) async {
    await tester.pumpWidget(
      _host(
        PreferencesController.ephemeral(),
        pr: _pr(
          checks: const [
            PrCheck(name: 'test', bucket: 'pass', workflowName: 'CI'),
          ],
        ),
        onInsert: (_) {},
      ),
    );
    expect(find.text('PR #42'), findsOneWidget);
    expect(find.byIcon(PhosphorIconsLight.gitPullRequest), findsOneWidget);
  });

  testWidgets('a merged PR reads as merged, not as a live PR', (tester) async {
    await tester.pumpWidget(
      _host(
        PreferencesController.ephemeral(),
        pr: _pr(
          state: 'MERGED',
          checks: const [
            PrCheck(name: 'test', bucket: 'pass', workflowName: 'CI'),
          ],
        ),
        onInsert: (_) {},
      ),
    );
    final icon = find.byIcon(PhosphorIconsLight.gitMerge);
    expect(icon, findsOneWidget);
    expect(find.byIcon(PhosphorIconsLight.gitPullRequest), findsNothing);
    expect(tester.widget<Icon>(icon).color, kPrMerged);
    // The label takes the AA-safe purple, not the vivid icon hue.
    expect(
      tester.widget<Text>(find.text('PR #42')).style?.color,
      Theme.of(tester.element(icon)).colorScheme.prMergedText,
    );
    // CI is moot once merged: no rollup dot tinted by the state colour.
    expect(find.byIcon(Icons.circle), findsNothing);
  });

  testWidgets('a closed PR reads as closed', (tester) async {
    await tester.pumpWidget(
      _host(
        PreferencesController.ephemeral(),
        pr: _pr(state: 'CLOSED', rollup: 'fail', unresolvedComments: 2),
        onInsert: (_) {},
      ),
    );
    final icon = findSvgAsset(kClosedPrAsset);
    expect(icon, findsOneWidget);
    // No PR-derived nudges once the PR is dead: CI and review threads are moot.
    expect(find.text('CI failing'), findsNothing);
    expect(find.text('2 unresolved comments'), findsNothing);
  });

  testWidgets('commits behind (no unpushed) → chip + default "Pull"', (
    tester,
  ) async {
    String? inserted;
    await tester.pumpWidget(
      _host(
        PreferencesController.ephemeral(),
        pr: _pr(unresolvedComments: 1),
        commitsBehind: 2,
        onInsert: (p) => inserted = p,
      ),
    );
    // Unfetched commits outrank unresolved comments.
    expect(find.text('2 commits behind'), findsOneWidget);
    expect(find.text('1 unresolved comment'), findsNothing);
    await tester.tap(find.text('Pull'));
    await tester.pumpAndSettle();
    expect(inserted, PrPromptAction.pull.defaultPrompt);
  });

  testWidgets('hovering the pill lists checks failed → skipped → passed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        PreferencesController.ephemeral(),
        pr: _pr(
          rollup: 'fail',
          checks: const [
            PrCheck(name: 'analyze', bucket: 'pass'),
            PrCheck(name: 'lint', bucket: 'skipping'),
            PrCheck(name: 'test', bucket: 'fail'),
          ],
        ),
        onInsert: (_) {},
      ),
    );

    // Hover the pill to reveal the popover.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('PR #42')));
    await tester.pumpAndSettle();

    // Rows are ordered failures first, then skipped, then passing.
    final failY = tester.getTopLeft(find.text('test')).dy;
    final skipY = tester.getTopLeft(find.text('lint')).dy;
    final passY = tester.getTopLeft(find.text('analyze')).dy;
    expect(failY, lessThan(skipY));
    expect(skipY, lessThan(passY));

    // Third column shows the human status word for each bucket.
    expect(find.text('failed'), findsOneWidget);
    expect(find.text('skipped'), findsOneWidget);
    expect(find.text('passed'), findsOneWidget);
  });

  for (final state in ['MERGED', 'CLOSED']) {
    testWidgets('hovering a $state PR reveals no CI history', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(
            state: state,
            rollup: 'fail',
            checks: const [
              PrCheck(name: 'analyze', bucket: 'pass'),
              PrCheck(name: 'test', bucket: 'fail'),
            ],
          ),
          onInsert: (_) {},
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.text('PR #42')));
      await tester.pumpAndSettle();

      // The checks are history once the PR is merged/closed: no popover, so no
      // check rows and no header claiming this is an open pull request.
      expect(find.text('analyze'), findsNothing);
      expect(find.text('test'), findsNothing);
      expect(find.textContaining('CI checks'), findsNothing);
      expect(find.textContaining('Open pull request'), findsNothing);
    });
  }

  // ── SPEC-32 §7.5 · stale pills + unmeasured counts ──────────────────────
  group('SPEC-32 stale pills', () {
    testWidgets('a stale PR still renders, dimmed', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(stale: true),
          onInsert: (_) {},
        ),
      );
      // The regression guard for the reported bug: a throttled lookup must NOT
      // erase the pill — its number and state glyph stay in the tree.
      expect(find.text('PR #42'), findsOneWidget);
      expect(find.byIcon(PhosphorIconsLight.gitPullRequest), findsOneWidget);
      // …and it is visibly de-emphasised (dimmed), not full strength.
      final opacity = _pillOpacity(tester);
      expect(opacity, isNotNull);
      expect(opacity, lessThan(1.0));
    });

    testWidgets('a fresh PR renders at full emphasis', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(stale: false),
          onInsert: (_) {},
        ),
      );
      // No dimming wrapper: the fresh pill is drawn at full strength, so the
      // dimmed-vs-fresh distinction is real and the stale test can't pass
      // vacuously.
      expect(find.text('PR #42'), findsOneWidget);
      expect(_pillOpacity(tester), isNull);
    });

    testWidgets('a stale pill names the reason in its tooltip', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(stale: true),
          onInsert: (_) {},
        ),
      );
      final tip = find.byTooltip(kStalePrTooltip);
      expect(tip, findsOneWidget);
      // The copy explains the *why* (a refresh that couldn't complete), not
      // just the label.
      expect(kStalePrTooltip, contains('Last known state'));
      expect(kStalePrTooltip.toLowerCase(), contains('quota'));
    });

    testWidgets('unresolvedUnknown hides the count instead of showing 0', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          // The 0 is a placeholder (the count was shed), not a fact — showing
          // "0 unresolved comments" would be a confident lie.
          pr: _pr(unresolvedComments: 0, unresolvedUnknown: true),
          onInsert: (_) {},
        ),
      );
      expect(find.textContaining('unresolved comment'), findsNothing);
    });

    testWidgets('a measured count still renders its number', (tester) async {
      await tester.pumpWidget(
        _host(
          PreferencesController.ephemeral(),
          pr: _pr(unresolvedComments: 3, unresolvedUnknown: false),
          onInsert: (_) {},
        ),
      );
      // Guards against hiding real data: a measured non-zero count is shown.
      expect(find.text('3 unresolved comments'), findsOneWidget);
    });
  });
}
