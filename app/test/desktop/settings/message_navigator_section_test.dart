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

  /// Taps [label], scrolling it into view first: the section is taller than the
  /// 600pt test viewport once a style's options expand.
  Future<void> tapRow(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

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

    await tapRow(tester, 'Off');

    expect(
      controller.get(messageNavigatorStylePreference),
      MessageNavigatorStyle.off,
    );
    expect(find.text('Tick spacing'), findsNothing);
    expect(find.text('Ripple on hover'), findsNothing);
  });

  testWidgets('every style is selectable and shows its own options', (
    tester,
  ) async {
    await pumpPrefs(tester);

    await tapRow(tester, 'Outline mode');
    expect(
      controller.get(messageNavigatorStylePreference),
      MessageNavigatorStyle.outline,
    );
    expect(find.text('Hide tool calls too'), findsOneWidget);
    expect(find.text('Tick spacing'), findsNothing);

    await tapRow(tester, 'Sticky breadcrumb');
    expect(find.text('Show position counter'), findsOneWidget);

    await tapRow(tester, 'Prompt palette');
    expect(find.text("Search the agent's messages too"), findsOneWidget);
  });

  testWidgets('the spacing segments write the preference', (tester) async {
    await pumpPrefs(tester);
    expect(controller.get(railTickSpacingPreference), 6);

    await tapRow(tester, 'roomy');
    expect(controller.get(railTickSpacingPreference), 14);

    await tapRow(tester, 'normal');
    expect(controller.get(railTickSpacingPreference), 10);
  });

  testWidgets('the option switches write their preferences', (tester) async {
    await pumpPrefs(tester);
    expect(controller.get(railRipplePreference), isTrue);

    await tapRow(tester, 'Ripple on hover');
    expect(controller.get(railRipplePreference), isFalse);

    await tapRow(tester, 'Tick length shows message length');
    expect(controller.get(railEncodeLengthPreference), isFalse);
  });

  testWidgets('options survive switching style away and back — the bug the '
      'mockup exposed', (tester) async {
    await pumpPrefs(tester);
    await tapRow(tester, 'roomy');

    await tapRow(tester, 'Off');
    expect(find.text('Tick spacing'), findsNothing);

    await tapRow(tester, 'Ripple rail');

    expect(controller.get(railTickSpacingPreference), 14);
    expect(find.text('Tick spacing'), findsOneWidget);
  });
}
