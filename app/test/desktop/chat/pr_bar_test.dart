import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/pr_actions.dart';
import 'package:makit/desktop/chat/pr_bar.dart';
import 'package:makit/desktop/settings/prefs/preference_entries.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
import 'package:makit/desktop/settings/prefs/preferences_providers.dart';
import 'package:makit/store/models.dart';

Widget _host(
  PreferencesController controller, {
  PullRequest? pr,
  required void Function(String) onInsert,
}) {
  return ProviderScope(
    overrides: [
      preferencesControllerProvider.overrideWith((ref) => controller),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: PrComposerBar(pr: pr, onInsertPrompt: onInsert),
      ),
    ),
  );
}

PullRequest _pr({
  String rollup = 'pass',
  bool isDraft = false,
  List<PrCheck> checks = const [],
}) => PullRequest(
  number: 42,
  url: 'https://github.com/o/r/pull/42',
  state: 'OPEN',
  title: 't',
  isDraft: isDraft,
  checkRollup: rollup,
  checks: checks,
);

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
  });
}
