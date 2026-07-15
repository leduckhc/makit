import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/desktop/settings/prefs/preference_entries.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
import 'package:makit/desktop/settings/prefs/preferences_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('sidebar layout providers persist through the preferences store', () {
    test('width seeds from the default and writes through on change', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = PreferencesController.load(prefs);
      final container = ProviderContainer(
        observers: const [SidebarLayoutPrefsObserver()],
        overrides: [
          preferencesControllerProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(sidebarWidthProvider), kSidebarDefaultWidth);

      container.read(sidebarWidthProvider.notifier).state = 400;
      await pumpEventQueue();

      // A fresh controller over the same prefs recovers the resized width.
      final reloaded = PreferencesController.load(prefs);
      expect(reloaded.get(sidebarWidthPreference), 400);
      expect(reloaded.isModified(sidebarWidthPreference), isTrue);
    });

    test('collapsed state seeds from and writes through the pref', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = PreferencesController.load(prefs);
      final container = ProviderContainer(
        observers: const [SidebarLayoutPrefsObserver()],
        overrides: [
          preferencesControllerProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(sidebarCollapsedProvider), isFalse);

      container.read(sidebarCollapsedProvider.notifier).state = true;
      await pumpEventQueue();

      final reloaded = PreferencesController.load(prefs);
      expect(reloaded.get(sidebarStartCollapsedPreference), isTrue);
    });

    test('a stored width seeds the provider on first read', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = PreferencesController.load(prefs);
      await controller.set(sidebarWidthPreference, 380.0);

      final container = ProviderContainer(
        observers: const [SidebarLayoutPrefsObserver()],
        overrides: [
          preferencesControllerProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(sidebarWidthProvider), 380.0);
    });

    test('resetting to the default removes the stored override', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final controller = PreferencesController.load(prefs);
      final container = ProviderContainer(
        observers: const [SidebarLayoutPrefsObserver()],
        overrides: [
          preferencesControllerProvider.overrideWith((ref) => controller),
        ],
      );
      addTearDown(container.dispose);

      container.read(sidebarWidthProvider.notifier).state = 400;
      await pumpEventQueue();
      expect(controller.isModified(sidebarWidthPreference), isTrue);

      container.read(sidebarWidthProvider.notifier).state = kSidebarDefaultWidth;
      await pumpEventQueue();
      expect(controller.isModified(sidebarWidthPreference), isFalse);
    });
  });

  group('text scale preference', () {
    testWidgets('applies to MediaQuery.textScaler when wired', (tester) async {
      final controller = PreferencesController.ephemeral();
      late TextScaler observed;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            preferencesControllerProvider.overrideWith((ref) => controller),
          ],
          child: const _TextScaleHarness(),
        ),
      );

      observed = tester
          .widget<MediaQuery>(find.byKey(const Key('text-scale-root')))
          .data
          .textScaler;
      expect(observed.scale(10), 10);

      await controller.set(textScalePreference, 1.3);
      await tester.pump();

      observed = tester
          .widget<MediaQuery>(find.byKey(const Key('text-scale-root')))
          .data
          .textScaler;
      expect(observed.scale(10), closeTo(13, 0.001));
    });
  });
}

/// Mirrors the production `MediaQuery.textScaler` wiring in `desktop_app.dart`:
/// the scale is read reactively from [textScalePreference] and applied via a
/// [MediaQuery] wrapper in the `MaterialApp.builder`.
class _TextScaleHarness extends ConsumerWidget {
  const _TextScaleHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textScaler = TextScaler.linear(ref.preference(textScalePreference));
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        key: const Key('text-scale-root'),
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child ?? const SizedBox(),
      ),
      home: const Scaffold(body: SizedBox()),
    );
  }
}
