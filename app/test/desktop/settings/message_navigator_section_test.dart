// T5 — SPEC-message-navigator: the Message navigator settings leaf.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/desktop/settings/sections/message_navigator_prefs.dart';
import 'package:makit/ui/session/navigator/navigator_style.dart';

void main() {
  late PreferencesController controller;

  /// Taps [label], scrolling it into view first: the section is taller than the
  /// 600pt test viewport once the rail's options expand.
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

  testWidgets('offers the rail, on by default, with its options', (
    tester,
  ) async {
    await pumpPrefs(tester);
    expect(find.text('Ripple rail'), findsOneWidget);
    expect(
      controller.get(messageNavigatorStylePreference),
      MessageNavigatorStyle.rail,
    );
    expect(find.text('Tick spacing'), findsOneWidget);
    expect(find.text('Ripple on hover'), findsOneWidget);
    expect(find.text('Tick length shows message length'), findsOneWidget);
  });

  testWidgets('turning the rail off hides its options', (tester) async {
    await pumpPrefs(tester);

    await tapRow(tester, 'Ripple rail');

    expect(
      controller.get(messageNavigatorStylePreference),
      MessageNavigatorStyle.off,
    );
    expect(find.text('Tick spacing'), findsNothing);
    expect(find.text('Ripple on hover'), findsNothing);
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

  testWidgets('options survive turning the rail off and on — the bug the '
      'mockup exposed', (tester) async {
    await pumpPrefs(tester);
    await tapRow(tester, 'roomy');

    await tapRow(tester, 'Ripple rail');
    expect(find.text('Tick spacing'), findsNothing);

    await tapRow(tester, 'Ripple rail');

    expect(controller.get(railTickSpacingPreference), 14);
    expect(find.text('Tick spacing'), findsOneWidget);
  });
}
