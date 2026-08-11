// Full-stack control-plane e2e for the macOS desktop control app (SPEC-03).
//
// Counterpart to the mobile stub suite (integration_test/stub/): instead of the
// WS client, this drives the real desktop control surface against a real daemon
// control socket served by `server/test/e2e-control-server.ts`. The whole stack
// is genuine — `MakitControlClient` speaks the real NDJSON protocol over the
// real unix socket to the real `createServerBackend`, and the real
// `ServerDevicesSection`/`DesktopController` render the responses.
//
// The socket path is injected by `app/tool/e2e-desktop.sh` via
// `--dart-define=MAKIT_CONTROL_SOCK`. We wire the same client/controller
// `runDesktopApp` builds, but pump the Server & Devices settings section
// directly so the test needs no tray/window native plugins.
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:makit/control/control_client.dart';
import 'package:makit/control/reconnecting_control_client.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/desktop_app.dart';
import 'package:makit/desktop/desktop_controller.dart';
import 'package:makit/desktop/screens/providers.dart';
import 'package:makit/desktop/settings/sections/server_devices_section.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:makit/store/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:makit/store/prefs/profile_scoped_prefs.dart';

const _socketPath = String.fromEnvironment('MAKIT_CONTROL_SOCK');
const _timeout = Duration(seconds: 20);

/// Pump at 100ms steps until [finder] matches or [_timeout] expires.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  String? reason,
}) async {
  final deadline = DateTime.now().add(_timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
  }
  fail(reason ?? 'timed out waiting for $finder');
}

/// Scrolls [finder] into view (the section is a long [ListView]) and taps it.
Future<void> _scrollAndTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Server & Devices section drives a real daemon control socket', (
    tester,
  ) async {
    expect(
      _socketPath.isNotEmpty,
      isTrue,
      reason: 'MAKIT_CONTROL_SOCK must be passed via --dart-define',
    );

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final client = ReconnectingControlClient(
      create: () => MakitControlClient(socketPath: _socketPath),
      connect: (c) => (c as MakitControlClient).connect(),
      dispose: (c) => (c as MakitControlClient).dispose(),
    );
    final controller = DesktopController(
      client: client,
      lifecycle: DaemonLifecycle(resolver: MakitCliResolver()),
    );
    addTearDown(() async {
      controller.dispose();
      await client.close();
    });
    controller.startPolling();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          controlClientProvider.overrideWithValue(client),
          desktopControllerProvider.overrideWithValue(controller),
          serverConfigProvider.overrideWith(
            (ref) => ServerConfigController(
              ProfileScopedPrefs.unscoped(prefs),
              const ServerConfig(),
            ),
          ),
          connectionProvider.overrideWithValue(MakitConnState()),
        ],
        child: const MaterialApp(home: Scaffold(body: ServerDevicesSection())),
      ),
    );

    // status → the lifecycle row renders the live pid over the real socket.
    await _pumpUntil(
      tester,
      find.textContaining('Running · pid'),
      reason:
          'lifecycle never showed a running daemon — control socket handshake '
          'or status verb failed',
    );

    // devices.list → expanding the Paired-devices row reveals the seeded
    // device inline.
    await _scrollAndTap(tester, find.text('Paired devices'));
    await _pumpUntil(
      tester,
      find.text('e2e phone'),
      reason: 'devices.list did not surface the seeded device',
    );
    await _scrollAndTap(tester, find.text('Paired devices')); // collapse

    // pair.mint → expanding the Pair-new-device row mints and renders a
    // makit:// pair url inline.
    await _scrollAndTap(tester, find.text('Pair new device'));
    await _pumpUntil(
      tester,
      find.textContaining('makit://pair'),
      reason: 'pair.mint did not return a pair url',
    );
    await _scrollAndTap(tester, find.text('Pair new device')); // collapse

    // sessions.list → expanding the Running-sessions row lists the seeded
    // default session inline.
    await _scrollAndTap(tester, find.text('Running sessions'));
    await _pumpUntil(
      tester,
      find.text('new session'),
      reason: 'sessions.list did not surface the default session',
    );
  });

  testWidgets('Reachability picker drives the unified ServerConfig', (
    tester,
  ) async {
    expect(
      _socketPath.isNotEmpty,
      isTrue,
      reason: 'MAKIT_CONTROL_SOCK must be passed via --dart-define',
    );

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final config = ServerConfigController(
      ProfileScopedPrefs.unscoped(prefs),
      const ServerConfig(),
    );

    final client = ReconnectingControlClient(
      create: () => MakitControlClient(socketPath: _socketPath),
      connect: (c) => (c as MakitControlClient).connect(),
      dispose: (c) => (c as MakitControlClient).dispose(),
    );
    final controller = DesktopController(
      client: client,
      lifecycle: DaemonLifecycle(resolver: MakitCliResolver()),
      serveArgs: () => config.current.serveArgs(),
    );
    addTearDown(() async {
      controller.dispose();
      await client.close();
    });
    controller.startPolling();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          controlClientProvider.overrideWithValue(client),
          desktopControllerProvider.overrideWithValue(controller),
          serverConfigProvider.overrideWith((ref) => config),
          connectionProvider.overrideWithValue(MakitConnState()),
        ],
        child: const MaterialApp(home: Scaffold(body: ServerDevicesSection())),
      ),
    );

    // The real daemon is up over the control socket (context for the section).
    await _pumpUntil(
      tester,
      find.textContaining('Running · pid'),
      reason: 'lifecycle never showed a running daemon',
    );

    // The real daemon is up (the active-profile row reads "Running").
    await _pumpUntil(
      tester,
      find.text('Running'),
      reason: 'active-profile row never showed a running daemon',
    );

    // Ships defaulting to "My devices" (the secure default), no host field.
    expect(config.current.reachability, Reachability.myDevices);
    expect(
      find.ancestor(of: find.text('Host'), matching: find.byType(TextField)),
      findsNothing,
    );

    // Selecting "Just this Mac" pins loopback in serveArgs.
    await _scrollAndTap(tester, find.text('Just this Mac'));
    await tester.pumpAndSettle();
    expect(config.current.reachability, Reachability.thisMacOnly);
    expect(
      config.current.serveArgs(),
      containsAllInOrder(['--host', '127.0.0.1']),
    );

    // The custom-host escape hatch lives under Diagnostics → Advanced.
    await _scrollAndTap(tester, find.text('Diagnostics'));
    await _scrollAndTap(tester, find.text('Advanced'));
    final host = find.ancestor(
      of: find.text('Host'),
      matching: find.byType(TextField),
    );
    expect(host, findsOneWidget);

    // Committing a host persists into the unified config + serveArgs.
    await tester.enterText(host, '0.0.0.0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(config.current.customHost, '0.0.0.0');
    expect(
      config.current.serveArgs(),
      containsAllInOrder(['--host', '0.0.0.0']),
    );
  });
}
