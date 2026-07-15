import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/control/control_types.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/desktop/screens/fake_control_client.dart';
import 'package:makit/desktop/screens/providers.dart';
import 'package:makit/desktop/settings/prefs/preference_entries.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
import 'package:makit/desktop/settings/prefs/preferences_providers.dart';
import 'package:makit/desktop/settings/sections/advanced_section.dart';

StatusData _status() => const StatusData(
  pid: 4242,
  uptimeMs: 90000,
  host: '127.0.0.1',
  port: 8080,
  fingerprint: 'ab:cd',
  advertiseHost: 'mac.local',
  pairedDevices: 1,
  runningSessions: 2,
  version: '0.1.0',
);

Future<void> _pump(
  WidgetTester tester,
  PreferencesController controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        preferencesControllerProvider.overrideWith((ref) => controller),
        controlClientProvider.overrideWithValue(
          FakeControlClient(status: _status()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: AdvancedSection())),
    ),
  );
  await tester.pump(); // fire the status future
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('renders status pid, uptime, and protocol version', (
    tester,
  ) async {
    await _pump(tester, PreferencesController.ephemeral());

    expect(find.text('Process id'), findsOneWidget);
    expect(find.text('4242'), findsOneWidget);
    expect(find.text('Uptime'), findsOneWidget);
    expect(find.text('1m'), findsOneWidget);
    expect(find.text('v1'), findsOneWidget); // protocolVersion == 1
  });

  testWidgets(
    'reset-all is disabled with no changes and shows a defaults note',
    (tester) async {
      await _pump(tester, PreferencesController.ephemeral());

      expect(find.text('All settings are at their defaults.'), findsOneWidget);
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Reset all'),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('reset-all clears every override after confirming', (
    tester,
  ) async {
    final controller = PreferencesController.ephemeral();
    await controller.set(themeModePreference, ThemeMode.dark);
    await _pump(tester, controller);

    expect(find.text('1 setting changed from default.'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reset all'));
    await tester.pumpAndSettle();
    // Confirm in the dialog (FilledButton labelled 'Reset all').
    await tester.tap(find.widgetWithText(FilledButton, 'Reset all'));
    await tester.pumpAndSettle();

    expect(controller.isModified(themeModePreference), isFalse);
    expect(find.text('All settings are at their defaults.'), findsOneWidget);
  });

  testWidgets('cancelling the reset dialog keeps overrides', (tester) async {
    final controller = PreferencesController.ephemeral();
    await controller.set(themeModePreference, ThemeMode.dark);
    await _pump(tester, controller);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reset all'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(controller.isModified(themeModePreference), isTrue);
  });

  testWidgets('reset-all re-seeds live sidebar width/collapsed to defaults', (
    tester,
  ) async {
    final controller = PreferencesController.ephemeral();
    await controller.set(themeModePreference, ThemeMode.dark);
    final container = ProviderContainer(
      overrides: [
        preferencesControllerProvider.overrideWith((ref) => controller),
        controlClientProvider.overrideWithValue(
          FakeControlClient(status: _status()),
        ),
      ],
    );
    addTearDown(container.dispose);
    // Move the live sidebar state away from its defaults.
    container.read(sidebarWidthProvider.notifier).state = 400;
    container.read(sidebarCollapsedProvider.notifier).state = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: AdvancedSection())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reset all'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset all'));
    await tester.pumpAndSettle();

    expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth);
    expect(container.read(sidebarCollapsedProvider), isFalse);
  });
}
