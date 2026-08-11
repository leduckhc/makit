import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/desktop_app.dart' show desktopControllerProvider;
import 'package:makit/desktop/desktop_controller.dart';
import 'package:makit/desktop/screens/fake_control_client.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_controller.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/desktop/settings/sections/appearance_section.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:makit/desktop/settings/settings_item_anchor.dart';
import 'package:makit/desktop/settings/settings_window.dart';
import 'package:makit/store/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:makit/store/prefs/profile_scoped_prefs.dart';

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

late SharedPreferences _prefs;

/// A [ProviderContainer] overriding the providers the Server & Devices section
/// body reads, so navigating to it (e.g. via a search deep-link) works. Shared
/// by [_wrap] and the deep-link test. Disposed automatically at test teardown.
///
/// (The overrides are an inferred list literal rather than a `List<Override>`
/// helper because Riverpod does not export the `Override` base type.)
ProviderContainer _sectionContainer({PreferencesController? controller}) {
  final container = ProviderContainer(
    overrides: [
      if (controller != null)
        preferencesControllerProvider.overrideWith((ref) => controller),
      serverConfigProvider.overrideWith(
        (ref) => ServerConfigController(
          ProfileScopedPrefs.unscoped(_prefs),
          const ServerConfig(),
        ),
      ),
      desktopControllerProvider.overrideWithValue(
        DesktopController(
          client: FakeControlClient(),
          lifecycle: DaemonLifecycle(
            resolver: MakitCliResolver(shellLookup: () async => null),
          ),
        ),
      ),
      connectionProvider.overrideWithValue(MakitConnState()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget _wrap(Widget child, {PreferencesController? controller}) =>
    UncontrolledProviderScope(
      container: _sectionContainer(controller: controller),
      child: MaterialApp(home: child),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('opens in-window without pushing a MaterialPageRoute', (
    tester,
  ) async {
    final observer = _RecordingObserver();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorObservers: [observer],
          home: Consumer(
            builder: (context, ref, _) => DesktopWindowBody(
              child: Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () =>
                        ref.read(settingsOpenProvider.notifier).state = true,
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    observer.pushed.clear(); // ignore the initial home route

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsWindow), findsOneWidget);
    expect(observer.pushed.whereType<MaterialPageRoute<dynamic>>(), isEmpty);
    // Default lastSection ('general') renders the General placeholder.
    expect(find.text('GENERAL'), findsOneWidget);
  });

  testWidgets('restores the last-selected section on open', (tester) async {
    final controller = PreferencesController.ephemeral();
    await controller.set(lastSectionPreference, 'appearance');
    await tester.pumpWidget(
      _wrap(SettingsWindow(onClose: () {}), controller: controller),
    );

    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.byType(AppearanceSection), findsOneWidget);
  });

  testWidgets('selecting a section persists settings.lastSection', (
    tester,
  ) async {
    final controller = PreferencesController.ephemeral();
    await tester.pumpWidget(
      _wrap(SettingsWindow(onClose: () {}), controller: controller),
    );

    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();

    expect(controller.get(lastSectionPreference), 'appearance');
    expect(find.byType(AppearanceSection), findsOneWidget);
  });

  testWidgets('search deep-links a result to its section and item', (
    tester,
  ) async {
    final controller = PreferencesController.ephemeral();
    final container = _sectionContainer(controller: controller);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: SettingsWindow(onClose: () {})),
      ),
    );

    await tester.enterText(find.byType(TextField), 'endpoint');
    await tester.pumpAndSettle();
    expect(find.text('Endpoint'), findsOneWidget);

    await tester.tap(find.text('Endpoint'));
    await tester.pumpAndSettle();
    expect(controller.get(lastSectionPreference), 'server_devices');
    // The deep-link records the specific item so its row can be revealed.
    expect(
      container.read(settingsTargetItemProvider),
      'server_devices.endpoint',
    );
    // The search field is cleared after picking a result (controlled field),
    // so no stale query lingers over the section list. It is the first
    // TextField (nav pane), before the detail pane's own fields.
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller?.text,
      '',
    );
  });

  testWidgets('close affordance invokes onClose', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      _wrap(SettingsWindow(onClose: () => closed = true)),
    );

    await tester.tap(find.byTooltip('Close settings'));
    await tester.pump();
    expect(closed, isTrue);
  });
}
