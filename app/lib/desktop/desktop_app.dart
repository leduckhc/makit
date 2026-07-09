/// macOS desktop control app entry point (SPEC-03, Phase 4).
///
/// Wires the tested building blocks into a launchable app:
/// - a [ReconnectingControlClient] over `~/.makit/control.sock`,
/// - a [DaemonLifecycle] driving `makit start/stop/restart`,
/// - a [DesktopController] polling daemon state,
/// - a `tray_manager` menubar item and a `window_manager` window that opens on
///   the **Devices (connected devices)** tab — never a pairing screen.
///
/// This file is the thin native-glue layer; the logic it orchestrates lives in
/// unit-tested classes (`DesktopController`, `ReconnectingControlClient`,
/// `DaemonLifecycle`, `TrayController`).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../app/theme.dart';
import '../control/control_client.dart';
import '../control/reconnecting_control_client.dart';
import 'daemon/daemon_lifecycle.dart';
import 'desktop_controller.dart';
import 'screens/devices_screen.dart';
import 'screens/providers.dart';
import 'screens/qr_screen.dart';
import 'screens/sessions_screen.dart';
import 'screens/status_screen.dart';
import 'tray/tray_controller.dart';

/// Exposes the [DesktopController] to the dashboard widgets.
final desktopControllerProvider = Provider<DesktopController>(
  (ref) => throw UnimplementedError('overridden in runDesktopApp'),
);

/// Which dashboard tab is showing; the tray's "Pair QR…" switches to QR.
final _selectedTab = ValueNotifier<int>(0);

String _controlSocketPath() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.makit/control.sock';
}

/// Boots the macOS desktop control app.
Future<void> runDesktopApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final socketPath = _controlSocketPath();
  final client = ReconnectingControlClient(
    create: () => MakitControlClient(socketPath: socketPath),
    connect: (c) => (c as MakitControlClient).connect(),
    dispose: (c) => (c as MakitControlClient).dispose(),
  );
  final lifecycle = DaemonLifecycle(resolver: MakitCliResolver());
  final controller = DesktopController(client: client, lifecycle: lifecycle);

  final tray = TrayController(
    stateAccessor: () => controller.summary,
    onStart: () => controller.start(),
    onStop: () => controller.stop(),
    onOpenDashboard: () {
      _selectedTab.value = 0;
      _showWindow();
    },
    onOpenQr: () {
      _selectedTab.value = 1;
      _showWindow();
    },
    // Real quit: cancel the poll timer, then terminate the process — which also
    // removes the tray icon. (windowManager.destroy alone left it running.)
    onQuit: () {
      controller.dispose();
      exit(0);
    },
  );
  await tray.init();
  // Keep the tray menu/tooltip in sync as the controller refreshes.
  controller.addListener(() => unawaited(tray.update(controller.summary)));

  // Poll the daemon so state stays fresh whether it is started from the app,
  // the CLI, or crashes underneath us.
  controller.startPolling();

  const options = WindowOptions(
    size: Size(760, 580),
    center: true,
    title: 'Makit',
    titleBarStyle: TitleBarStyle.normal,
  );
  unawaited(
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    }),
  );

  runApp(
    ProviderScope(
      overrides: [
        controlClientProvider.overrideWithValue(client),
        desktopControllerProvider.overrideWithValue(controller),
      ],
      child: const _DesktopApp(),
    ),
  );
}

Future<void> _showWindow() async {
  await windowManager.show();
  await windowManager.focus();
}

/// Copies the makit install one-liner to the clipboard and confirms via snackbar.
void _copyInstallCommand(BuildContext context) {
  unawaited(Clipboard.setData(const ClipboardData(text: makitInstallCommand)));
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Install command copied to clipboard')),
  );
}

class _DesktopApp extends StatelessWidget {
  const _DesktopApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Makit',
      debugShowCheckedModeBanner: false,
      theme: makitLightTheme,
      darkTheme: makitDarkTheme,
      themeMode: ThemeMode.system,
      home: const DesktopDashboard(),
    );
  }
}

/// The control dashboard: a header with server state + Start/Stop/Restart and a
/// navigation rail. Home tab is **Devices** (connected devices).
class DesktopDashboard extends ConsumerStatefulWidget {
  /// Creates the dashboard.
  const DesktopDashboard({super.key});

  @override
  ConsumerState<DesktopDashboard> createState() => _DesktopDashboardState();
}

class _DesktopDashboardState extends ConsumerState<DesktopDashboard> {
  static const _tabs = <Widget>[
    DevicesScreen(),
    QrScreen(),
    SessionsScreen(),
    StatusScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(desktopControllerProvider);
    return AnimatedBuilder(
      animation: Listenable.merge([controller, _selectedTab]),
      builder: (context, _) {
        final summary = controller.summary;
        return Scaffold(
          body: Column(
            children: [
              _Header(controller: controller),
              if (controller.cliMissing)
                CliMissingBanner(onInstall: () => _copyInstallCommand(context)),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  children: [
                    NavigationRail(
                      selectedIndex: _selectedTab.value,
                      onDestinationSelected: (i) => _selectedTab.value = i,
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        NavigationRailDestination(
                          icon: const Icon(Icons.devices),
                          label: Text('Devices (${summary.pairedDevices})'),
                        ),
                        const NavigationRailDestination(
                          icon: Icon(Icons.qr_code_2),
                          label: Text('Pair QR'),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.list_alt),
                          label: Text('Sessions (${summary.runningSessions})'),
                        ),
                        const NavigationRailDestination(
                          icon: Icon(Icons.info_outline),
                          label: Text('Status'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _tabs[_selectedTab.value]),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final DesktopController controller;

  @override
  Widget build(BuildContext context) {
    final summary = controller.summary;
    final running = summary.state == DaemonState.running;
    final busy = summary.state == DaemonState.starting;
    final (color, label) = switch (summary.state) {
      DaemonState.running => (
        Colors.green,
        'Server running (pid ${summary.pid})',
      ),
      DaemonState.starting => (Colors.orange, 'Starting…'),
      DaemonState.stopped => (Colors.grey, 'Server stopped'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.circle, size: 12, color: color),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (!running)
            FilledButton.icon(
              onPressed: busy ? null : () => controller.start(),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start'),
            ),
          if (running) ...[
            OutlinedButton.icon(
              onPressed: () => controller.restart(),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Restart'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => controller.stop(),
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ],
        ],
      ),
    );
  }
}

/// The documented one-line installer for the makit CLI (see issue #13 / README).
const String makitInstallCommand =
    'curl -fsSL https://raw.githubusercontent.com/leduckhc/makit/main/install.sh | bash';

/// Shown when the `makit` CLI cannot be located. Offers an actionable recovery:
/// copy the install command (per SPEC-03 "must not hard-fail").
class CliMissingBanner extends StatelessWidget {
  /// Creates the banner. [onInstall] runs when the action button is tapped.
  const CliMissingBanner({required this.onInstall, super.key});

  /// Invoked when the user taps the install action.
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'The makit CLI was not found. Install it to start/stop the server '
              'from here.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onInstall,
            icon: const Icon(Icons.copy_all),
            label: const Text('Copy install command'),
          ),
        ],
      ),
    );
  }
}
