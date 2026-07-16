import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/desktop/settings/prefs/preference_entries.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
import 'package:makit/desktop/settings/prefs/preferences_providers.dart';
import 'package:makit/desktop/settings/sections/appearance_section.dart';

Future<PreferencesController> _pump(WidgetTester tester) async {
  // Give the test a tall viewport so the whole (scrollable) section — including
  // the text-scale slider — is laid out on-screen and hit-testable by drag().
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final controller = PreferencesController.ephemeral();
  await tester.pumpWidget(
    ProviderScope(
      observers: const [SidebarLayoutPrefsObserver()],
      overrides: [
        preferencesControllerProvider.overrideWith((ref) => controller),
      ],
      child: const MaterialApp(home: Scaffold(body: AppearanceSection())),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('renders Layout and Text subsections with real controls', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('LAYOUT'), findsOneWidget);
    expect(find.text('TEXT'), findsOneWidget);
    expect(find.text('Default sidebar width'), findsOneWidget);
    expect(find.text('Start with sidebar collapsed'), findsOneWidget);
    expect(find.text('UI text scale'), findsOneWidget);
    // Reserved leaves remain visible but disabled.
    expect(find.text('Coming soon'), findsWidgets);
  });

  testWidgets('toggling start-collapsed writes the layout pref', (
    tester,
  ) async {
    final controller = await _pump(tester);
    expect(controller.isModified(sidebarStartCollapsedPreference), isFalse);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(controller.get(sidebarStartCollapsedPreference), isTrue);
    expect(controller.isModified(sidebarStartCollapsedPreference), isTrue);
  });

  testWidgets('changing the text scale writes and can be reset', (
    tester,
  ) async {
    final controller = await _pump(tester);

    // Drag the text-scale slider to a larger value.
    final slider = find.byType(Slider).last;
    await tester.drag(slider, const Offset(200, 0));
    await tester.pump();
    expect(controller.isModified(textScalePreference), isTrue);

    await tester.tap(find.byTooltip('Reset to default').last);
    await tester.pump();
    expect(controller.isModified(textScalePreference), isFalse);
  });
}
