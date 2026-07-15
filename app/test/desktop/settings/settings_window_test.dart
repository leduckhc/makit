import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/desktop_app.dart' show desktopControllerProvider;
import 'package:makit/desktop/desktop_controller.dart';
import 'package:makit/desktop/screens/fake_control_client.dart';
import 'package:makit/desktop/settings/prefs/preference_entries.dart';
import 'package:makit/desktop/settings/prefs/preferences_controller.dart';
import 'package:makit/desktop/settings/prefs/preferences_providers.dart';
import 'package:makit/desktop/settings/sections/appearance_section.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:makit/desktop/settings/settings_window.dart';
import 'package:makit/store/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

late SharedPreferences _prefs;

Widget _wrap(
  Widget child, {
  PreferencesController? controller,
}) => ProviderScope(
  // The Server & Devices section body reads these providers, so navigating to
  // it (e.g. via a search deep-link) requires them to be overridden.
  overrides: [
    if (controller != null)
      preferencesControllerProvider.overrideWith((ref) => controller),
    serverConfigProvider.overrideWith(
      (ref) => ServerConfigController(_prefs, const ServerConfig()),
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

  testWidgets('search deep-links a result to its section', (tester) async {
    final controller = PreferencesController.ephemeral();
    await tester.pumpWidget(
      _wrap(SettingsWindow(onClose: () {}), controller: controller),
    );

    await tester.enterText(find.byType(TextField), 'endpoint');
    await tester.pumpAndSettle();
    expect(find.text('Endpoint'), findsOneWidget);

    await tester.tap(find.text('Endpoint'));
    await tester.pumpAndSettle();
    expect(controller.get(lastSectionPreference), 'server_devices');
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
