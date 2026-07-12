// Full-stack control-plane e2e for the macOS desktop control app (SPEC-03).
//
// Counterpart to the mobile stub suite (integration_test/stub/): instead of the
// WS client, this drives the real desktop control screens against a real daemon
// control socket served by `server/test/e2e-control-server.ts`. The whole stack
// is genuine — `MakitControlClient` speaks the real NDJSON protocol over the
// real unix socket to the real `createServerBackend`, and the real
// `DesktopDashboard`/`DesktopController` render the responses.
//
// The socket path is injected by `app/tool/e2e-desktop.sh` via
// `--dart-define=MAKIT_CONTROL_SOCK`. We wire the same client/controller
// `runDesktopApp` builds, but pump `DesktopDashboard` directly so the test
// needs no tray/window native plugins.
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop dashboard drives a real daemon control socket', (
    tester,
  ) async {
    expect(
      _socketPath.isNotEmpty,
      isTrue,
      reason: 'MAKIT_CONTROL_SOCK must be passed via --dart-define',
    );

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
        ],
        child: const MaterialApp(home: DesktopDashboard()),
      ),
    );

    // status → the header renders the live pid over the real socket.
    await _pumpUntil(
      tester,
      find.textContaining('Server running (pid'),
      reason:
          'header never showed a running daemon — control socket handshake '
          'or status verb failed',
    );

    // devices.list → the seeded device shows on the (default) Devices tab.
    await _pumpUntil(
      tester,
      find.text('e2e phone'),
      reason: 'devices.list did not surface the seeded device',
    );

    // pair.mint → the QR tab mints and renders a makit:// pair url.
    await tester.tap(find.text('Pair QR'));
    await _pumpUntil(
      tester,
      find.textContaining('makit://pair'),
      reason: 'pair.mint did not return a pair url',
    );

    // sessions.list → the Sessions tab lists the seeded default session.
    await tester.tap(find.textContaining('Sessions ('));
    await _pumpUntil(
      tester,
      find.text('new session'),
      reason: 'sessions.list did not surface the default session',
    );
  });
}
