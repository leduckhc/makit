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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/theme.dart';
import '../control/control_client.dart';
import '../control/reconnecting_control_client.dart';
import '../shortcuts/keymap_controller.dart';
import '../store/connection.dart';
import '../store/recent_models.dart';
import '../store/secure_store.dart';
import '../store/store.dart';
import '../ui/widgets/srv_request_handler.dart';
import 'chat/desktop_auto_select.dart';
import 'chat/desktop_session_prune.dart';
import 'chat/desktop_chat_bootstrap.dart';
import 'chat/desktop_chat_shell.dart';
import 'chat/keymap_scope.dart';
import 'chat/loopback_pairing.dart';
import 'chat/groups/groups_controller.dart';
import 'chat/sidebar_layout.dart';
import 'daemon/daemon_lifecycle.dart';
import 'daemon/server_profile.dart';
import 'desktop_controller.dart';
import 'screens/providers.dart';
import '../ui/session/navigator/navigator_style.dart';
import 'settings/prefs/navigator_preference_bridge.dart';
import 'settings/prefs/preference_entries.dart';
import 'settings/prefs/preferences_controller.dart';
import 'settings/prefs/preferences_providers.dart';
import 'settings/server_config.dart';
import 'settings/settings_window.dart';
import 'tray/tray_controller.dart';

/// Exposes the [DesktopController] to the dashboard widgets.
final desktopControllerProvider = Provider<DesktopController>(
  (ref) => throw UnimplementedError('overridden in runDesktopApp'),
);

/// The isolated server profile this app instance runs against (per build).
/// Self-derives from the running executable by default (so widget tests need no
/// override); [runDesktopApp] overrides it with the already-derived profile.
final serverProfileProvider = Provider<ServerProfile>(
  (ref) => ServerProfile.resolve(),
);

/// Navigator for the chat window, so the sidebar can push the Settings/Server
/// page from a callback created above the [Navigator].
final _desktopNavKey = GlobalKey<NavigatorState>();

/// Boots the macOS desktop control app.
Future<void> runDesktopApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Per-build isolation: a `main` build and a worktree build each get their own
  // MAKIT_HOME, port, prefs namespace, and window label so two windows never
  // collide. The installed app keeps the historical ~/.makit + 7777 defaults.
  final profile = ServerProfile.resolve();

  final socketPath = profile.controlSocketPath;
  final client = ReconnectingControlClient(
    create: () => MakitControlClient(socketPath: socketPath),
    connect: (c) => (c as MakitControlClient).connect(),
    dispose: (c) => (c as MakitControlClient).dispose(),
  );
  // Namespace SharedPreferences per profile (dev builds only) so a worktree
  // window's settings don't overwrite main's. Must run before getInstance().
  if (!profile.isDefault) SharedPreferences.setPrefix(profile.prefsPrefix);
  final prefs = await SharedPreferences.getInstance();
  final configController = ServerConfigController(
    prefs,
    ServerConfigController.load(prefs, defaultPort: profile.port),
    defaultPort: profile.port,
  );
  final lifecycle = DaemonLifecycle(
    resolver: MakitCliResolver(
      // Honor the user's optional CLI-path override (read live so a settings
      // change takes effect without an app restart).
      overridePath: () => configController.current.cliPath,
    ),
    // Pass MAKIT_HOME so the spawned daemon writes its socket/pid/db under this
    // profile's home — matching the control socket the app connects to above.
    environment: profile.environment,
  );
  final keymapController = KeymapController.load(
    prefs,
    cmdIsPrimary: cmdIsPrimaryModifier,
  );
  final preferencesController = PreferencesController.load(prefs);
  final recentModelsController = RecentModelsController.load(prefs);
  final groupsController = GroupsController.load(prefs);
  final controller = DesktopController(
    client: client,
    lifecycle: lifecycle,
    serveArgs: () => configController.current.serveArgs(),
  );

  final tray = TrayController(
    stateAccessor: () => controller.summary,
    onStart: () => controller.start(),
    onStop: () => controller.stop(),
    onOpenDashboard: _showWindow,
    onOpenQr: _showWindow,
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

  final options = WindowOptions(
    size: const Size(1120, 760),
    center: true,
    title: profile.windowTitle,
    // Frameless look: hide the OS titlebar and let Flutter draw to the top of
    // the window. On macOS the traffic-light buttons stay; the sidebar header
    // (a DragToMoveArea) insets below them and doubles as the window drag
    // handle. See docs/research/flutter-desktop-titlebar-window-managers.md.
    titleBarStyle: TitleBarStyle.hidden,
  );
  unawaited(
    windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
      // Distinguish windows in Cmd-Tab / the Window menu / Mission Control.
      await windowManager.setTitle(profile.windowTitle);
    }),
  );

  runApp(
    ProviderScope(
      observers: const [SidebarLayoutPrefsObserver()],
      overrides: [
        controlClientProvider.overrideWithValue(client),
        desktopControllerProvider.overrideWithValue(controller),
        serverProfileProvider.overrideWithValue(profile),
        // Per-profile pairing bearer so main and worktree builds never clobber
        // each other's stored server (a shared bearer wedged the app into
        // permanent "Reconnecting").
        secureStorageProvider.overrideWithValue(
          defaultSecureStore(namespace: profile.isDefault ? null : profile.id),
        ),
        serverConfigProvider.overrideWith((ref) => configController),
        keymapProvider.overrideWith((ref) => keymapController),
        preferencesControllerProvider.overrideWith(
          (ref) => preferencesController,
        ),
        recentModelsControllerProvider.overrideWith(
          (ref) => recentModelsController,
        ),
        groupsControllerProvider.overrideWith((ref) => groupsController),
        // SPEC-34: hand the stored navigator style + rail options to the shared
        // transcript providers (shared `ui/` cannot read `desktop/` prefs).
        messageNavigatorStyleProvider.overrideWith(
          (ref) => ref.watch(desktopNavigatorStyleProvider),
        ),
        railOptionsProvider.overrideWith(
          (ref) => ref.watch(desktopRailOptionsProvider),
        ),
      ],
      child: const _DesktopApp(),
    ),
  );
}

Future<void> _showWindow() async {
  await windowManager.show();
  await windowManager.focus();
}

class _DesktopApp extends ConsumerStatefulWidget {
  const _DesktopApp();

  @override
  ConsumerState<_DesktopApp> createState() => _DesktopAppState();
}

class _DesktopAppState extends ConsumerState<_DesktopApp> {
  @override
  void initState() {
    super.initState();
    // Eagerly create the store controller so it subscribes to the connection's
    // frame stream before the WS connects and starts pushing snapshots
    // (mirrors the mobile bootstrap in `main.dart`).
    ref.read(storeControllerProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrapConnection());
    });
  }

  /// Bring the local daemon up (if needed), then self-pair over loopback so the
  /// reused chat stack can talk to it. Best-effort: on failure the window stays
  /// on its empty state and the user can retry via Settings & Server.
  Future<void> _bootstrapConnection() async {
    final controller = ref.read(desktopControllerProvider);
    final conn = ref.read(connectionControllerProvider.notifier);
    final pairing = LoopbackPairing(
      control: ref.read(controlClientProvider),
      // The desktop app's own client always talks to the daemon over loopback,
      // regardless of how the daemon binds for other devices.
      host: '127.0.0.1',
      isPaired: () => ref.read(connectionProvider).paired,
      pairWith: (info, {String label = 'Mac'}) async {
        await conn.pairWith(info, label: label);
      },
    );
    final boot = DesktopChatBootstrap(
      ensureDaemonRunning: () => _ensureDaemonRunning(controller),
      ensurePaired: pairing.ensurePaired,
    );
    await boot.run();
  }

  /// Start the daemon only if one isn't already reachable, then wait until it
  /// reports running.
  ///
  /// We refresh first (an authoritative control-socket probe) because a daemon
  /// may already be listening — including one started by another makit worktree
  /// sharing this `~/.makit` home + port. Calling `makit start` in that case
  /// collides with `EADDRINUSE`; refreshing first lets us just use it.
  Future<bool> _ensureDaemonRunning(DesktopController controller) async {
    await controller.refresh();
    if (controller.summary.state == DaemonState.running) return true;
    await controller.start();
    for (var i = 0; i < 24; i++) {
      if (controller.summary.state == DaemonState.running) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await controller.refresh();
    }
    return controller.summary.state == DaemonState.running;
  }

  /// Shows the two-pane Settings window in-window (no route push) so it opens
  /// instantly and the chat state underneath is preserved (SPEC-13 #5).
  void _openSettings() {
    ref.read(settingsOpenProvider.notifier).state = true;
  }

  @override
  Widget build(BuildContext context) {
    // Close tabs whose session no longer exists server-side (archived or quit
    // from another client, or a restored layout pointing at dead sessions)
    // BEFORE auto-select, so it sees the pruned workspace.
    ref.watch(desktopSessionPruneProvider);
    // SPEC-10: auto-select the most recent session when none is picked.
    ref.watch(desktopAutoSelectSessionProvider);
    // Read reactively here (not inside `builder`, which builds in a descendant
    // context) so changing the pref rebuilds and re-wires the reminder delay.
    final reminderDelay = Duration(
      minutes: ref.preference(notificationsReminderDelayPreference),
    );
    // UI text scale (SPEC-13 Appearance → Text). Applied via a MediaQuery
    // wrapper in `builder` so it scales the whole app, dialogs included.
    final textScaler = TextScaler.linear(ref.preference(textScalePreference));
    return MaterialApp(
      title: 'Makit',
      navigatorKey: _desktopNavKey,
      debugShowCheckedModeBanner: false,
      scrollBehavior: const _NoScrollbarBehavior(),
      theme: makitLightTheme,
      darkTheme: makitDarkTheme,
      themeMode: ref.preference(themeModePreference),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: SrvRequestHandler(
          navigatorKey: _desktopNavKey,
          // Desktop is the control surface: always show the in-app dialog, and
          // only fall back to a system notification if it goes unanswered.
          reminderDelay: reminderDelay,
          child: child ?? const SizedBox(),
        ),
      ),
      home: DesktopKeymapScope(
        onOpenSettings: _openSettings,
        child: DesktopWindowBody(
          child: DesktopChatShell(onOpenSettings: _openSettings),
        ),
      ),
    );
  }
}

/// App-wide scroll behavior that suppresses scrollbars everywhere (transcript,
/// sidebar, pickers). Modern trackpads/wheels make persistent scrollbars
/// unnecessary; content still scrolls normally.
class _NoScrollbarBehavior extends MaterialScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

/// The documented one-line installer for the makit CLI (see issue #13 / README).
const String makitInstallCommand =
    'curl -fsSL https://raw.githubusercontent.com/leduckhc/makit/main/install.sh | bash';
