// Mobile Appearance settings (SPEC-desktop-settings-rework on the phone): theme mode and text scale,
// persisted through the shared preferences layer and applied to the app root.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/settings/appearance_settings.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

ProviderContainer _container([SharedPreferences? prefs]) {
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      projectsProvider.overrideWithValue(ProjectsState(const [])),
      sessionsProvider.overrideWithValue(SessionsState(const [])),
      if (prefs != null)
        preferencesControllerProvider.overrideWith(
          (ref) => PreferencesController.load(prefs),
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AppearanceSettingsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('picking a theme stores it', (tester) async {
    final container = _container();
    await _pump(tester, container);

    expect(container.read(themeModeValueProvider), ThemeMode.system);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(container.read(themeModeValueProvider), ThemeMode.dark);
  });

  testWidgets('dragging text size changes the scale', (tester) async {
    final container = _container();
    await _pump(tester, container);

    expect(container.read(textScaleValueProvider), 1.0);

    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pumpAndSettle();

    expect(container.read(textScaleValueProvider), greaterThan(1.0));
  });

  testWidgets('the choice survives a restart', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();

    final first = _container(prefs);
    await _pump(tester, first);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(first.read(themeModeValueProvider), ThemeMode.light);

    // A fresh container over the same storage is what a relaunch looks like.
    final second = _container(prefs);
    expect(second.read(themeModeValueProvider), ThemeMode.light);
  });
}
