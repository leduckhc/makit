import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/cli_installer.dart';
import 'package:makit/desktop/daemon/daemon_lifecycle.dart';
import 'package:makit/desktop/desktop_app.dart' show desktopControllerProvider;
import 'package:makit/desktop/desktop_controller.dart';
import 'package:makit/desktop/screens/fake_control_client.dart';
import 'package:makit/desktop/screens/providers.dart'
    show cliInstallerProvider, controlClientProvider;
import 'package:makit/desktop/settings/sections/server_devices_section.dart';
import 'package:makit/desktop/settings/server_config.dart';
import 'package:makit/store/connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

Future<void> _pump(
  WidgetTester tester, {
  required ServerConfigController config,
  DesktopController? controller,
  MakitConnState? connection,
  CliInstaller? installer,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        serverConfigProvider.overrideWith((ref) => config),
        desktopControllerProvider.overrideWithValue(
          controller ?? _controller(),
        ),
        connectionProvider.overrideWithValue(connection ?? MakitConnState()),
        if (installer != null)
          cliInstallerProvider.overrideWithValue(installer),
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
    expect(find.text('Endpoint'), findsOneWidget);
    expect(find.text('Lifecycle'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('DEVICES'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('SESSIONS'), findsOneWidget);
  });

  testWidgets('defaults to Auto and has no Save button', (tester) async {
    final config = await makeConfig();
    await _pump(tester, config: config);

    expect(config.current.bindMode, ServerBindMode.auto);
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Save'), findsNothing);

    // Auto mode shows no host field.
    expect(
      find.ancestor(of: find.text('Host'), matching: find.byType(TextField)),
      findsNothing,
    );
  });

  testWidgets('selecting LAN persists the bind mode', (tester) async {
    final config = await makeConfig();
    await _pump(tester, config: config);

    await tester.tap(find.text('LAN'));
    await tester.pump();

    expect(config.current.bindMode, ServerBindMode.lan);
  });

  testWidgets('Custom reveals a host field that applies on commit', (
    tester,
  ) async {
    final config = await makeConfig();
    await _pump(tester, config: config);

    await tester.tap(find.text('Custom'));
    await tester.pump();
    expect(config.current.bindMode, ServerBindMode.custom);

    final host = find.ancestor(
      of: find.text('Host'),
      matching: find.byType(TextField),
    );
    await tester.enterText(host, '0.0.0.0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(config.current.customHost, '0.0.0.0');
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
    // Tall viewport so the fingerprint row (in the Server group) is on-screen
    // and its copy button is hit-testable.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Capture what the copy button writes to the system clipboard.
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
      server: PairedServer(
        host: 'h',
        port: 7788,
        fingerprint: fingerprint,
        bearer: 'b',
        label: 'Mac',
      ),
    );
    await _pump(tester, config: await makeConfig(), connection: connected);

    expect(find.byTooltip('Copy fingerprint'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy fingerprint'));
    await tester.pump();

    // The full fingerprint is copied (the subtitle only shows a shortened form).
    expect(copied, fingerprint);
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
    // Tall viewport so every row lays out (a ListView doesn't build far
    // off-screen children) and is hit-testable without scrolling.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final config = await makeConfig();
    final observer = _RecordingObserver();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverConfigProvider.overrideWith((ref) => config),
          desktopControllerProvider.overrideWithValue(_controller()),
          connectionProvider.overrideWithValue(MakitConnState()),
          controlClientProvider.overrideWithValue(
            FakeControlClient(sessions: const []),
          ),
        ],
        child: MaterialApp(
          navigatorObservers: [observer],
          home: const Scaffold(body: ServerDevicesSection()),
        ),
      ),
    );
    await tester.pump();
    observer.pushed.clear();

    // Collapsed: the row's inline content is not built yet.
    expect(find.text('No running sessions'), findsNothing);

    await tester.tap(find.text('Running sessions'));
    await tester.pumpAndSettle();

    // Expanded inline — content is revealed and nothing was pushed onto the
    // navigator.
    expect(find.text('No running sessions'), findsOneWidget);
    expect(observer.pushed.whereType<MaterialPageRoute<dynamic>>(), isEmpty);
  });

  testWidgets('rows behave as an accordion (opening one closes the other)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final config = await makeConfig();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverConfigProvider.overrideWith((ref) => config),
          desktopControllerProvider.overrideWithValue(_controller()),
          connectionProvider.overrideWithValue(MakitConnState()),
          controlClientProvider.overrideWithValue(
            FakeControlClient(devices: const [], sessions: const []),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: ServerDevicesSection())),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Paired devices'));
    await tester.pumpAndSettle();
    expect(find.text('No paired devices'), findsOneWidget);

    await tester.tap(find.text('Running sessions'));
    await tester.pumpAndSettle();

    // Opening Sessions collapses the previously-open Devices row.
    expect(find.text('No running sessions'), findsOneWidget);
    expect(find.text('No paired devices'), findsNothing);
  });

  group('Install CLI button', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('cli_install_ui'));
    tearDown(() => tmp.deleteSync(recursive: true));

    CliInstaller installerWithBundle({required bool bundled}) {
      final path = '${tmp.path}/Resources/makit/makit';
      if (bundled) {
        File(path).createSync(recursive: true);
      }
      return CliInstaller(bundledCliPath: () => path, homeDir: () => tmp.path);
    }

    Future<void> scrollToCli(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        find.text('CLI'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
    }

    testWidgets('shown when the app bundles a CLI; installs on tap', (
      tester,
    ) async {
      await _pump(
        tester,
        config: await makeConfig(),
        installer: installerWithBundle(bundled: true),
      );
      await scrollToCli(tester);

      final button = find.text('Install CLI');
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pump();
      await tester.pump();

      expect(File('${tmp.path}/.local/bin/makit').existsSync(), isTrue);
      expect(find.textContaining('Installed makit CLI'), findsOneWidget);
    });

    testWidgets('hidden when the build has no bundled CLI', (tester) async {
      await _pump(
        tester,
        config: await makeConfig(),
        installer: installerWithBundle(bundled: false),
      );
      await scrollToCli(tester);

      expect(find.text('Install CLI'), findsNothing);
    });
  });
}
