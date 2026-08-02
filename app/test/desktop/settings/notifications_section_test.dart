import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/desktop/settings/sections/notifications_section.dart';

/// Mirrors the production wiring in `desktop_app.dart`: the reminder delay is
/// read reactively from [notificationsReminderDelayPreference].
class _DelayHarness extends ConsumerWidget {
  const _DelayHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final minutes = ref.preference(notificationsReminderDelayPreference);
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Text('delay:$minutes', textDirection: TextDirection.ltr),
            const Expanded(child: NotificationsSection()),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('renders the section header and a coming-soon placeholder', (
    tester,
  ) async {
    final controller = PreferencesController.ephemeral();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesControllerProvider.overrideWith((ref) => controller),
        ],
        child: const _DelayHarness(),
      ),
    );

    expect(find.text('NOTIFICATIONS'), findsOneWidget);
    expect(find.text('Reminder delay'), findsOneWidget);
    expect(find.text('Per-type mute & approval reminders'), findsOneWidget);
    expect(find.text('Coming soon'), findsOneWidget);
    // Defaults to 2 minutes and shows no reset affordance while unmodified.
    expect(find.text('delay:2'), findsOneWidget);
    expect(find.byTooltip('Reset to default'), findsNothing);
  });

  testWidgets('changing the reminder delay updates the value the app reads', (
    tester,
  ) async {
    final controller = PreferencesController.ephemeral();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesControllerProvider.overrideWith((ref) => controller),
        ],
        child: const _DelayHarness(),
      ),
    );

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 minutes').last);
    await tester.pumpAndSettle();

    expect(controller.get(notificationsReminderDelayPreference), 5);
    expect(find.text('delay:5'), findsOneWidget);
    expect(controller.isModified(notificationsReminderDelayPreference), isTrue);
  });

  testWidgets('reset restores the default reminder delay', (tester) async {
    final controller = PreferencesController.ephemeral();
    await controller.set(notificationsReminderDelayPreference, 10);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesControllerProvider.overrideWith((ref) => controller),
        ],
        child: const _DelayHarness(),
      ),
    );

    expect(find.text('delay:10'), findsOneWidget);
    expect(find.text('Modified'), findsOneWidget);

    await tester.tap(find.byTooltip('Reset to default'));
    await tester.pumpAndSettle();

    expect(controller.get(notificationsReminderDelayPreference), 2);
    expect(
      controller.isModified(notificationsReminderDelayPreference),
      isFalse,
    );
    expect(find.text('delay:2'), findsOneWidget);
  });
}
