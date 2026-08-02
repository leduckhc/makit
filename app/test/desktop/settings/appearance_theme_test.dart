import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/desktop/settings/sections/appearance_section.dart';

/// Mirrors the production `MaterialApp.themeMode` wiring in `desktop_app.dart`:
/// the theme mode is read reactively from [themeModePreference].
class _ThemeHarness extends ConsumerWidget {
  const _ThemeHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      theme: makitLightTheme,
      darkTheme: makitDarkTheme,
      themeMode: ref.preference(themeModePreference),
      home: const Scaffold(body: AppearanceSection()),
    );
  }
}

void main() {
  testWidgets('changing the Theme pref flips MaterialApp.themeMode', (
    tester,
  ) async {
    final controller = PreferencesController.ephemeral();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesControllerProvider.overrideWith((ref) => controller),
        ],
        child: const _ThemeHarness(),
      ),
    );

    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().themeMode, ThemeMode.system);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.dark);
    expect(controller.get(themeModePreference), ThemeMode.dark);

    // Reset affordance appears once modified and reverts to System.
    await tester.tap(find.byTooltip('Reset to default'));
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.system);
    expect(controller.isModified(themeModePreference), isFalse);
  });
}
