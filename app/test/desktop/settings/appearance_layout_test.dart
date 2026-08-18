import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
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

/// The [Switch] inside the settings row titled [rowTitle].
Finder _switchIn(String rowTitle) => find.descendant(
  of: find.widgetWithText(ListTile, rowTitle),
  matching: find.byType(Switch),
);

void main() {
  testWidgets('the auto-split threshold row writes the preference', (
    tester,
  ) async {
    // SPEC-tab-groups decision 9: the control sets a placement policy. It is a plain
    // segmented control because the value is small and bounded.
    final controller = await _pump(tester);

    expect(find.text('Agents side by side'), findsOneWidget);
    expect(controller.get(autoSplitThresholdPreference), 3);

    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<int>),
        matching: find.text('5'),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.get(autoSplitThresholdPreference), 5);
    expect(controller.isModified(autoSplitThresholdPreference), isTrue);
  });

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

    // Addressed by its row: Layout has more than one switch since SPEC-preview-groups.
    await tester.tap(_switchIn('Start with sidebar collapsed'));
    await tester.pump();

    expect(controller.get(sidebarStartCollapsedPreference), isTrue);
    expect(controller.isModified(sidebarStartCollapsedPreference), isTrue);
  });

  testWidgets('the preview-groups switch is off by default and writes', (
    tester,
  ) async {
    // SPEC-preview-groups decision 9: opt-in, because the mode trades a browsed group's
    // arrangement for a rail that stays short.
    final controller = await _pump(tester);

    expect(find.text('Preview tabs for worktrees'), findsOneWidget);
    expect(controller.get(previewGroupsPreference), isFalse);

    await tester.tap(_switchIn('Preview tabs for worktrees'));
    await tester.pump();

    expect(controller.get(previewGroupsPreference), isTrue);
    expect(controller.isModified(previewGroupsPreference), isTrue);

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Preview tabs for worktrees'),
        matching: find.byTooltip('Reset to default'),
      ),
    );
    await tester.pump();
    expect(controller.isModified(previewGroupsPreference), isFalse);
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
