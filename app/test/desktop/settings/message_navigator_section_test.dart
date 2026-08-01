// T5 — SPEC-34: the Message navigator settings leaf.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/prefs/preference_entries.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
import 'package:makit/desktop/settings/prefs/preferences_providers.dart';
import 'package:makit/desktop/settings/sections/message_navigator_prefs.dart';
import 'package:makit/ui/session/navigator/navigator_style.dart';

void main() {
  late PreferencesController controller;

  Future<void> pumpPrefs(WidgetTester tester) async {
    controller = PreferencesController.ephemeral();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: MessageNavigatorPrefs()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists every style, with rail selected by default', (
    tester,
  ) async {
    await pumpPrefs(tester);
    for (final title in const [
      'Off',
      'Ripple rail',
      'Prompt scrubber',
      'Prompt palette',
      'Sticky breadcrumb',
      'Outline mode',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(
      controller.get(messageNavigatorStylePreference),
      MessageNavigatorStyle.rail,
    );
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
  });

  testWidgets('only the selected style shows its options', (tester) async {
    await pumpPrefs(tester);
    // Rail is selected, so its three options are present.
    expect(find.text('Tick spacing'), findsOneWidget);
    expect(find.text('Ripple on hover'), findsOneWidget);
    expect(find.text('Tick length shows message length'), findsOneWidget);

    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();

    expect(
      controller.get(messageNavigatorStylePreference),
      MessageNavigatorStyle.off,
    );
    expect(find.text('Tick spacing'), findsNothing);
    expect(find.text('Ripple on hover'), findsNothing);
  });

  testWidgets('unbuilt styles are disabled and marked coming soon', (
    tester,
  ) async {
    await pumpPrefs(tester);
    expect(find.text('coming soon'), findsNWidgets(4));

    await tester.tap(find.text('Prompt scrubber'));
    await tester.pumpAndSettle();

    expect(
      controller.get(messageNavigatorStylePreference),
      MessageNavigatorStyle.rail,
      reason: 'tapping an unbuilt style must not select it',
    );
  });

  testWidgets('the spacing segments write the preference', (tester) async {
    await pumpPrefs(tester);
    expect(controller.get(railTickSpacingPreference), 6);

    await tester.tap(find.text('roomy'));
    await tester.pumpAndSettle();
    expect(controller.get(railTickSpacingPreference), 14);

    await tester.tap(find.text('normal'));
    await tester.pumpAndSettle();
    expect(controller.get(railTickSpacingPreference), 10);
  });

  testWidgets('the option switches write their preferences', (tester) async {
    await pumpPrefs(tester);
    expect(controller.get(railRipplePreference), isTrue);

    await tester.tap(find.text('Ripple on hover'));
    await tester.pumpAndSettle();
    expect(controller.get(railRipplePreference), isFalse);

    await tester.tap(find.text('Tick length shows message length'));
    await tester.pumpAndSettle();
    expect(controller.get(railEncodeLengthPreference), isFalse);
  });

  testWidgets('options survive switching style away and back — the bug the '
      'mockup exposed', (tester) async {
    await pumpPrefs(tester);
    await tester.tap(find.text('roomy'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(find.text('Tick spacing'), findsNothing);

    await tester.tap(find.text('Ripple rail'));
    await tester.pumpAndSettle();

    expect(controller.get(railTickSpacingPreference), 14);
    expect(find.text('Tick spacing'), findsOneWidget);
  });
}
