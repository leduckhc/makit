import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/daemon/server_profile.dart';
import 'package:makit/desktop/desktop_app.dart'
    show desktopControllerProvider, serverProfileProvider;
import 'package:makit/desktop/desktop_controller.dart';
import 'package:makit/desktop/screens/fake_control_client.dart';
import 'package:makit/desktop/screens/providers.dart'
    show controlClientProvider;
import 'package:makit/desktop/settings/sections/server_devices_section.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_event.dart';
import 'package:makit/status/status_providers.dart';
import 'package:makit/store/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:makit/store/prefs/profile_scoped_prefs.dart';

/// Records pushed routes so a test can assert no page was navigated to.
class _RecordingObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

DesktopController _controller() => DesktopController(
  client: FakeControlClient(),
  lifecycle: DaemonLifecycle(
    resolver: MakitCliResolver(
      candidatePaths: const ['/opt/homebrew/bin/makit'],
      exists: (path) => path == '/opt/homebrew/bin/makit',
      shellLookup: () async => null,
    ),
  ),
);

/// A controller whose CLI always succeeds, without touching a real binary.
DesktopController _okController() => DesktopController(
  client: FakeControlClient(),
  lifecycle: DaemonLifecycle(
    resolver: MakitCliResolver(
      candidatePaths: const ['/opt/homebrew/bin/makit'],
      exists: (path) => path == '/opt/homebrew/bin/makit',
      shellLookup: () async => null,
    ),
    run: (exe, args) async => ProcessResult(0, 0, '', ''),
  ),
);

/// A controller whose CLI always fails, reporting [stdout] the way the real
/// `makit start` does -- on stdout, with stderr empty (see `_failureMessage` in
/// `daemon_lifecycle.dart`).
DesktopController _failingController(String stdout) => DesktopController(
  client: FakeControlClient(),
  lifecycle: DaemonLifecycle(
    resolver: MakitCliResolver(
      candidatePaths: const ['/opt/homebrew/bin/makit'],
      exists: (path) => path == '/opt/homebrew/bin/makit',
      shellLookup: () async => null,
    ),
    run: (exe, args) async => ProcessResult(0, 1, stdout, ''),
  ),
);

Future<void> _pump(
  WidgetTester tester, {
  required ServerConfigController config,
  DesktopController? controller,
  MakitConnState? connection,
  StatusCenter? statusCenter,
  ServerProfile? profile,
  NavigatorObserver? observer,
  bool tall = false,
}) async {
  if (tall) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serverConfigProvider.overrideWith((ref) => config),
        serverProfileProvider.overrideWithValue(profile ?? _testProfile()),
        desktopControllerProvider.overrideWithValue(
          controller ?? _controller(),
        ),
        connectionProvider.overrideWithValue(connection ?? MakitConnState()),
        controlClientProvider.overrideWithValue(
          FakeControlClient(devices: const [], sessions: const []),
        ),
        if (statusCenter != null)
          statusCenterProvider.overrideWithValue(statusCenter),
      ],
      child: MaterialApp(
        navigatorObservers: observer == null ? const [] : [observer],
        home: const Scaffold(body: ServerDevicesSection()),
      ),
    ),
  );
  await tester.pump();
}

ServerProfile _testProfile() => const ServerProfile(
  id: 'work',
  name: 'Work',
  kind: ProfileKind.user,
  home: '/Users/test/.makit',
  port: 7777,
  storage: ProfileStorage.legacy,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ServerConfigController> makeConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return ServerConfigController(
      ProfileScopedPrefs.unscoped(prefs),
      const ServerConfig(),
    );
  }

  testWidgets('renders the four-row Server group and subsection headers', (
    tester,
  ) async {
    await _pump(tester, config: await makeConfig());
    expect(find.text('SERVER & DEVICES'), findsOneWidget);
    expect(find.text('SERVER'), findsOneWidget);
    expect(find.text('Who can reach this server?'), findsOneWidget);
    expect(find.text('Pair a phone'), findsOneWidget);
    expect(find.text('Diagnostics'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(find.text('DEVICES'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('SESSIONS'), findsOneWidget);
  });

  testWidgets('active-profile row shows the profile name and a status', (
    tester,
  ) async {
    await _pump(tester, config: await makeConfig());
    expect(find.text('Work'), findsOneWidget);
    expect(
      find.text(
        'Projects, agents, devices and sessions are separate per profile.',
      ),
      findsOneWidget,
    );
    // Daemon is stopped in tests → the status reads "Stopped".
    expect(find.text('Stopped'), findsOneWidget);
  });

  testWidgets('defaults to My devices and has no Save button', (tester) async {
    final config = await makeConfig();
    await _pump(tester, config: config);

    expect(config.current.reachability, Reachability.myDevices);
    expect(find.text('Save & restart server'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);

    // The LAN fallback checkbox is shown under "My devices"; it is off.
    expect(config.current.allowLanFallback, isFalse);
    expect(
      find.text('Also allow plain Wi-Fi when Tailscale is off'),
      findsOneWidget,
    );
  });

  testWidgets('selecting "Just this Mac" persists thisMacOnly + restarts', (
    tester,
  ) async {
    final config = await makeConfig();
    final controller = _okController();
    addTearDown(controller.dispose);
    await _pump(tester, config: config, controller: controller);

    await tester.tap(find.text('Just this Mac'));
    await tester.pumpAndSettle();

    expect(config.current.reachability, Reachability.thisMacOnly);
  });

  testWidgets('the LAN fallback checkbox toggles allowLanFallback', (
    tester,
  ) async {
    final config = await makeConfig();
    final controller = _okController();
    addTearDown(controller.dispose);
    await _pump(tester, config: config, controller: controller);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(config.current.allowLanFallback, isTrue);
  });

  testWidgets('a failed restart after a reachability change is reported', (
    tester,
  ) async {
    final center = StatusCenter();
    addTearDown(center.dispose);
    final controller = _failingController(
      'makit: failed to start \u2014 no response within 3000ms '
      '(see /Users/le/.makit-dev/a1b2c3d4/makit.log)',
    );
    addTearDown(controller.dispose);
    await _pump(
      tester,
      config: await makeConfig(),
      controller: controller,
      statusCenter: center,
    );

    await tester.tap(find.text('Just this Mac'));
    await tester.pumpAndSettle();

    expect(
      center.events.where((e) => e.severity == StatusSeverity.failure),
      isNotEmpty,
    );
    expect(center.events.last.detail, contains('makit.log'));
  });

  testWidgets('Install CLI does not live in this section (moved to General)', (
    tester,
  ) async {
    await _pump(tester, config: await makeConfig(), tall: true);
    expect(find.text('Install CLI'), findsNothing);
  });

  group('Diagnostics disclosure', () {
    testWidgets('is collapsed until tapped, then reveals the moved rows', (
      tester,
    ) async {
      await _pump(tester, config: await makeConfig(), tall: true);

      // Collapsed: none of the moved rows are built yet.
      expect(find.text('Lifecycle'), findsNothing);

      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();

      expect(find.text('Lifecycle'), findsOneWidget);
      expect(find.text('CLI'), findsOneWidget);
      expect(find.text('Fingerprint / TLS trust'), findsOneWidget);
      expect(find.text('Advanced'), findsOneWidget);
    });

    testWidgets('Advanced applies a valid port on commit', (tester) async {
      final config = await makeConfig();
      final controller = _okController();
      addTearDown(controller.dispose);
      await _pump(tester, config: config, controller: controller, tall: true);

      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();

      final port = find.ancestor(
        of: find.text('Port'),
        matching: find.byType(TextField),
      );
      await tester.enterText(port, '9000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(config.current.port, 9000);
    });

    testWidgets('Advanced rejects an out-of-range port and keeps config', (
      tester,
    ) async {
      final config = await makeConfig();
      final controller = _okController();
      addTearDown(controller.dispose);
      await _pump(tester, config: config, controller: controller, tall: true);

      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();

      final port = find.ancestor(
        of: find.text('Port'),
        matching: find.byType(TextField),
      );
      await tester.enterText(port, '70000');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(config.current.port, kDefaultServerPort);
      expect(
        find.text('Port must be a number between 1 and 65535.'),
        findsOneWidget,
      );
    });

    testWidgets('a failed Lifecycle "Start" is reported', (tester) async {
      final center = StatusCenter();
      addTearDown(center.dispose);
      final controller = _failingController(
        'makit: failed to start \u2014 no response within 3000ms',
      );
      addTearDown(controller.dispose);
      await _pump(
        tester,
        config: await makeConfig(),
        controller: controller,
        statusCenter: center,
        tall: true,
      );

      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(
        center.events.where((e) => e.severity == StatusSeverity.failure),
        isNotEmpty,
      );
      expect(center.events.last.detail, contains('failed to start'));
    });

    testWidgets('shows the fingerprint with a copy action when connected', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      const fingerprint = 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';
      final connected = MakitConnState(
        servers: [
          PairedServer(
            host: 'h',
            port: 7788,
            fingerprint: fingerprint,
            bearer: 'b',
            label: 'Mac',
          ),
        ],
        activeId: fingerprint,
      );
      await _pump(
        tester,
        config: await makeConfig(),
        connection: connected,
        tall: true,
      );

      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Copy fingerprint'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy fingerprint'));
      await tester.pump();
      expect(copied, fingerprint);
    });
  });

  testWidgets('unpair shows a confirm dialog that can be cancelled', (
    tester,
  ) async {
    await _pump(tester, config: await makeConfig());

    await tester.dragUntilVisible(
      find.widgetWithText(OutlinedButton, 'Unpair'),
      find.byType(ListView),
      const Offset(0, -100),
    );
    await tester.pumpAndSettle();
    expect(find.text('DANGER ZONE'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Unpair'));
    await tester.pumpAndSettle();
    expect(find.text('Unpair this device?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Unpair this device?'), findsNothing);
  });

  testWidgets('nav rows disclose their content inline (no page push)', (
    tester,
  ) async {
    final observer = _RecordingObserver();
    await _pump(
      tester,
      config: await makeConfig(),
      observer: observer,
      tall: true,
    );
    observer.pushed.clear();

    expect(find.text('No running sessions'), findsNothing);

    await tester.tap(find.text('Running sessions'));
    await tester.pumpAndSettle();

    expect(find.text('No running sessions'), findsOneWidget);
    expect(observer.pushed.whereType<MaterialPageRoute<dynamic>>(), isEmpty);
  });

  testWidgets('rows behave as an accordion (opening one closes the other)', (
    tester,
  ) async {
    await _pump(tester, config: await makeConfig(), tall: true);

    await tester.tap(find.text('Paired devices'));
    await tester.pumpAndSettle();
    expect(find.text('No paired devices'), findsOneWidget);

    await tester.tap(find.text('Running sessions'));
    await tester.pumpAndSettle();

    expect(find.text('No running sessions'), findsOneWidget);
    expect(find.text('No paired devices'), findsNothing);
  });
}
