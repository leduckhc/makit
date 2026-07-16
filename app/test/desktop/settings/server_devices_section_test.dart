import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/desktop_app.dart' show desktopControllerProvider;
import 'package:makit/desktop/desktop_controller.dart';
import 'package:makit/desktop/screens/fake_control_client.dart';
import 'package:makit/desktop/settings/sections/server_devices_section.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:makit/store/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> _pump(
  WidgetTester tester, {
  required ServerConfigController config,
  DesktopController? controller,
  MakitConnState? connection,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serverConfigProvider.overrideWith((ref) => config),
        desktopControllerProvider.overrideWithValue(
          controller ?? _controller(),
        ),
        connectionProvider.overrideWithValue(connection ?? MakitConnState()),
      ],
      child: const MaterialApp(home: Scaffold(body: ServerDevicesSection())),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ServerConfigController> makeConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return ServerConfigController(prefs, const ServerConfig());
  }

  testWidgets('renders the section with its subsection headers', (
    tester,
  ) async {
    await _pump(tester, config: await makeConfig());

    expect(find.text('SERVER & DEVICES'), findsOneWidget);
    expect(find.text('SERVER'), findsOneWidget);
    expect(find.text('DEVICES'), findsOneWidget);
    expect(find.text('Endpoint'), findsOneWidget);
    expect(find.text('Lifecycle'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('SESSIONS'), findsOneWidget);
  });

  testWidgets('has no Save button — endpoint applies host on field commit', (
    tester,
  ) async {
    final config = await makeConfig();
    await _pump(tester, config: config);

    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Save'), findsNothing);

    final host = find.widgetWithText(TextField, 'localhost');
    await tester.enterText(host, '127.0.0.1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(config.current.host, '127.0.0.1');
  });

  testWidgets('endpoint applies a valid port on commit', (tester) async {
    final config = await makeConfig();
    await _pump(tester, config: config);

    final port = find.ancestor(
      of: find.text('Port'),
      matching: find.byType(TextField),
    );
    await tester.enterText(port, '9000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(config.current.port, 9000);
  });

  testWidgets('endpoint rejects an out-of-range port and keeps config', (
    tester,
  ) async {
    final config = await makeConfig();
    await _pump(tester, config: config);

    final port = find.ancestor(
      of: find.text('Port'),
      matching: find.byType(TextField),
    );
    await tester.enterText(port, '70000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(config.current.port, kDefaultServerPort);
    expect(
      find.text('Port must be a number between 1 and 65535.'),
      findsOneWidget,
    );
  });

  testWidgets('shows the fingerprint with a copy action when connected', (
    tester,
  ) async {
    final connected = MakitConnState(
      server: PairedServer(
        host: 'h',
        port: 8787,
        fingerprint: 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99',
        bearer: 'b',
        label: 'Mac',
      ),
    );
    await _pump(tester, config: await makeConfig(), connection: connected);

    expect(find.byTooltip('Copy fingerprint'), findsOneWidget);
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
}
