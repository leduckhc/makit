/// macOS desktop control app entry point (SPEC-desktop-control-app, Phase 4).
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

import '../status/activity_badge.dart';
import '../status/status_toast.dart';
import '../app/theme.dart';
import '../control/reconnecting_control_client.dart';
import '../shortcuts/keymap_controller.dart';
import '../store/cached_commands.dart';
import '../store/connection.dart';
import '../store/ports.dart';
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
import 'daemon/profile_deleter.dart';
import 'daemon/profile_registry.dart';
import 'daemon/profile_runtime.dart';
import 'daemon/server_profile.dart';
import 'settings/sections/profiles_providers.dart';
import 'desktop_controller.dart';
import 'desktop_ports_route.dart';
import 'screens/providers.dart';
import '../store/prefs/navigator_preference_bridge.dart';
import '../store/prefs/preference_entries.dart';
import '../store/prefs/preferences_controller.dart';
import '../store/prefs/preferences_providers.dart';
import '../ui/session/navigator/navigator_style.dart';
import 'settings/server_config.dart';
import 'settings/settings_window.dart';
import 'tray/tray_controller.dart';
import 'tray/tray_ports.dart';

/// Exposes the [DesktopController] to the dashboard widgets.
final desktopControllerProvider = Provider<DesktopController>(
  (ref) => throw UnimplementedError('overridden in runDesktopApp'),
);

/// The server profile this app instance runs against.
///
/// Defaults to [ServerProfile.bootstrap] so widget tests need no override;
/// [runDesktopApp] replaces it with the profile [ProfileRegistry] resolved,
/// which is the one with a persisted identity and a probed port.
final serverProfileProvider = Provider<ServerProfile>(
  (ref) => ServerProfile.bootstrap(),
);

/// The registry backing [serverProfileProvider]. Overridden alongside it so the
/// Profiles UI can list, create, rename and delete without re-reading the file.
final profileRegistryProvider = Provider<ProfileRegistry>(
  (ref) => throw UnimplementedError('overridden in runDesktopApp'),
);

/// Navigator for the chat window, so the sidebar can push the Settings/Server
/// page from a callback created above the [Navigator].
final _desktopNavKey = GlobalKey<NavigatorState>();

/// Boots the macOS desktop control app.
Future<void> runDesktopApp() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  // Per-profile isolation: a `main` build and a worktree build each get their
  // own MAKIT_HOME, port, prefs namespace and window label so two windows never
  // collide. Identity is persisted in ~/.makit/profiles.json rather than derived
  // from this executable's path, so moving or rebuilding a worktree re-binds to
  // the same profile instead of orphaning it (SPEC-profiles D3).
  final resolvedHome = Platform.environment['HOME'] ?? '';
  final registry = ProfileRegistry.load(makitRoot: '$resolvedHome/.makit');
  final resolution = await registry.resolveFor(
    executablePath: Platform.resolvedExecutable,
    home: resolvedHome,
  );
  // Honour the profile the user last switched to, but only for the installed
  // app: a dev build always opens its own profile (SPEC-profiles D10).
  final profile = registry.preferredFor(resolution.profile);
  // Only write when the set actually changed: launching must not rewrite the
  // registry (and bump its mtime) on every start.
  if (resolution.created) registry.save();

  final prefs = await SharedPreferences.getInstance();
  final runtime = ProfileRuntime.create(
    profile: profile,
    registry: registry,
    prefs: prefs,
  );

  final keymapController = KeymapController.load(
    prefs,
    cmdIsPrimary: cmdIsPrimaryModifier,
  );
  final preferencesController = PreferencesController.load(prefs);
  final recentModelsController = RecentModelsController.load(prefs);
  // SPEC-starter-pane-parity: the starter pane's slash palette, remembered across restarts —
  // otherwise every relaunch shows it empty until a session has run.
  final cachedCommandsController = CachedCommandsController.load(prefs);
  // The tray must read the runtime through a holder, not close over one
  // DesktopController: after a profile switch the old controller is disposed, and
  // a menubar still pointing at it would drive a dead object.
  final host = _ProfileHostState.holder;
  host.runtime = runtime;
  final tray = TrayController(
    stateAccessor: () => host.runtime.controller.summary,
    onStart: () => host.runtime.controller.start(),
    onStop: () => host.runtime.controller.stop(),
    onOpenDashboard: _showWindow,
    onOpenQr: _showWindow,
    // SPEC-ports-global-view D15: the menubar's one ports action. The desktop shell is not a
    // router app, so this pushes on its own Navigator — the same helper the
    // ⌘⇧P shortcut and the worktree menu use, guard included.
    onOpenPorts: () async {
      await _showWindow();
      await DesktopPortsRoute.open(_desktopNavKey.currentState);
    },
    // Real quit: cancel the poll timer, then terminate the process — which also
    // removes the tray icon. (windowManager.destroy alone left it running.)
    onQuit: () {
      host.runtime.controller.dispose();
      exit(0);
    },
  );
  await tray.init();
  host.tray = tray;
  // Keep the tray menu/tooltip in sync as the active controller refreshes. The
  // listener is re-attached on every switch (see _ProfileHostState._adopt).
  host.attachTray();

  // Poll the daemon so state stays fresh whether it is started from the app,
  // the CLI, or crashes underneath us.
  runtime.startPolling();

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
    _ProfileHost(
      prefs: prefs,
      registry: registry,
      keymapController: keymapController,
      preferencesController: preferencesController,
      recentModelsController: recentModelsController,
      cachedCommandsController: cachedCommandsController,
      tray: tray,
    ),
  );
}

Future<void> _showWindow() async {
  await windowManager.show();
  await windowManager.focus();
}

class _DesktopApp extends ConsumerStatefulWidget {
  const _DesktopApp({this.tray});

  /// The macOS tray, when there is one — fed the app's cached ports snapshot
  /// (D15: the menubar renders the cache and never arms the scanner).
  final TrayController? tray;

  @override
  ConsumerState<_DesktopApp> createState() => _DesktopAppState();
}

class _DesktopAppState extends ConsumerState<_DesktopApp>
    with WidgetsBindingObserver {
  ProviderSubscription<PortsSnapshot?>? _portsSub;
  @override
  void initState() {
    super.initState();
    // Eagerly create the store controller so it subscribes to the connection's
    // frame stream before the WS connects and starts pushing snapshots
    // (mirrors the mobile bootstrap in `main.dart`).
    ref.read(storeControllerProvider);
    // SPEC-ports-global-view D15: mirror each ports snapshot the app already receives into the
    // menubar. A LISTENER, not a watch: the tray must never be the reason the
    // host runs `lsof`, so an idle window with no ports surface open simply
    // leaves the submenu showing the last snapshot it saw.
    final tray = widget.tray;
    if (tray != null) {
      _portsSub = ref.listenManual(portsProvider, (_, next) {
        unawaited(tray.setPorts(trayPortLabels(next, ref.read(reposProvider))));
      });
    }
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrapConnection());
    });
  }

  @override
  void dispose() {
    _portsSub?.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Same foreground definition as the rest of the app (see
    // srv_request_handler): `inactive` is a transient overlay, still on screen.
    // macOS throttles frames for a hidden window but never touches timers, so
    // the daemon poll has to back off on its own.
    final visible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    ref.read(desktopControllerProvider).setWindowVisible(visible);
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
  /// instantly and the chat state underneath is preserved (SPEC-desktop-settings-rework #5).
  void _openSettings() {
    ref.read(settingsOpenProvider.notifier).state = true;
  }

  @override
  Widget build(BuildContext context) {
    // Close tabs whose session no longer exists server-side (closed or quit
    // from another client, or a restored layout pointing at dead sessions)
    // BEFORE auto-select, so it sees the pruned workspace.
    ref.watch(desktopSessionPruneProvider);
    // SPEC-desktop-chat-app: auto-select the most recent session when none is picked.
    ref.watch(desktopAutoSelectSessionProvider);
    // Read reactively here (not inside `builder`, which builds in a descendant
    // context) so changing the pref rebuilds and re-wires the reminder delay.
    final reminderDelay = Duration(
      minutes: ref.preference(notificationsReminderDelayPreference),
    );
    // UI text scale (SPEC-desktop-settings-rework Appearance → Text). Applied via a MediaQuery
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
        // SPEC-status-and-activity: the same toast layer as mobile. Tapping one opens Activity in
        // its dialog; the sidebar bell is the other way in.
        child: StatusToastLayer(
          topInset: kToastInsetDesktop,
          onOpen: (event) {
            final context = _desktopNavKey.currentContext;
            if (context != null) unawaited(showActivityDialog(context));
          },
          child: SrvRequestHandler(
            navigatorKey: _desktopNavKey,
            // Desktop is the control surface: always show the in-app dialog, and
            // only fall back to a system notification if it goes unanswered.
            reminderDelay: reminderDelay,
            child: child ?? const SizedBox(),
          ),
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

/// A mutable holder for the active [ProfileRuntime].
///
/// The tray and the poll loop are created before the widget tree exists and must
/// survive a profile switch, so they read the runtime through this rather than
/// closing over one instance (SPEC-profiles D10).
class _RuntimeHolder {
  late ProfileRuntime runtime;
  TrayController? tray;
  VoidCallback? _trayListener;
  DesktopController? _trayTarget;

  /// (Re)attaches the tray's sync listener to the current runtime's controller.
  void attachTray() {
    final t = tray;
    if (t == null) return;
    final previous = _trayListener;
    final previousTarget = _trayTarget;
    // Detach from the EXACT controller the listener was added to. The caller has
    // already swapped `runtime` to the new one, so `runtime.controller` is the
    // wrong instance — removing from it is a no-op and leaks the listener on the
    // old controller.
    if (previous != null && previousTarget != null) {
      // Best effort: the old controller may already be disposed.
      try {
        previousTarget.removeListener(previous);
      } on FlutterError {
        /* already disposed */
      }
    }
    void listener() => unawaited(t.update(runtime.controller.summary));
    _trayListener = listener;
    _trayTarget = runtime.controller;
    runtime.controller.addListener(listener);
    unawaited(t.update(runtime.controller.summary));
  }
}

/// Hosts the app and swaps the whole per-profile object graph on a switch.
///
/// The switch is a **key change on the `ProviderScope`**: Riverpod then disposes
/// the entire old container deterministically, so there is no hand-written
/// teardown list to forget an entry as the app grows.
class _ProfileHost extends StatefulWidget {
  const _ProfileHost({
    required this.prefs,
    required this.registry,
    required this.keymapController,
    required this.preferencesController,
    required this.recentModelsController,
    required this.cachedCommandsController,
    required this.tray,
  });

  final SharedPreferences prefs;
  final ProfileRegistry registry;
  final KeymapController keymapController;
  final PreferencesController preferencesController;
  final RecentModelsController recentModelsController;
  final CachedCommandsController cachedCommandsController;
  final TrayController? tray;

  @override
  State<_ProfileHost> createState() => _ProfileHostState();
}

class _ProfileHostState extends State<_ProfileHost> {
  /// Shared with `runDesktopApp`, which builds the first runtime and the tray
  /// before any widget exists.
  static final _RuntimeHolder holder = _RuntimeHolder();

  ProfileRuntime get _runtime => holder.runtime;

  /// True while a [switchTo] is mid-flight, so a second switch cannot start
  /// before the first resolves. Both the title-bar badge and the Profiles
  /// section call `switchTo` through `profileSwitcherProvider`, so guarding here
  /// serialises every entry point: two interleaved switches could otherwise each
  /// replace the shared runtime and write `lastActive`, leaving the window on
  /// one profile while persistence and the title name another.
  bool _switching = false;

  /// Switches to [target], verifying it is reachable BEFORE tearing anything
  /// down (SPEC-profiles D10 step 2).
  ///
  /// Returns `null` on success, or a human-readable reason on failure — in which
  /// case nothing has changed and the caller reports it. The order is the whole
  /// point: start and confirm the target while the current profile is still
  /// live, so a target that cannot come up leaves the window exactly as it was.
  /// Switches to [target], verifying it is reachable BEFORE tearing anything
  /// down, and optionally deleting [deleteAfter] once the switch has landed.
  ///
  /// Returns `null` on success, or a human-readable reason on failure — in which
  /// case nothing has changed and the caller reports it.
  ///
  /// [deleteAfter] exists because `ProfileDeleter` refuses the *active* profile
  /// by design (D8), so "switch away and delete" cannot be done by the widget
  /// that offers it: the ProviderScope it lives in is disposed by the switch. The
  /// host survives that rebuild, so it runs the delete afterwards through the NEW
  /// runtime's deleter, which correctly sees the old profile as inactive.
  Future<ProfileSwitchResult> switchTo(
    ServerProfile target, {
    ServerProfile? deleteAfter,
  }) async {
    if (target.id == _runtime.profile.id) {
      return (switchFailure: null, deleteFailure: null);
    }
    if (_switching) {
      return (
        switchFailure:
            'a profile switch is already in progress — wait for it to finish',
        deleteFailure: null,
      );
    }
    _switching = true;
    try {
      return await _switchTo(target, deleteAfter: deleteAfter);
    } finally {
      _switching = false;
    }
  }

  Future<ProfileSwitchResult> _switchTo(
    ServerProfile target, {
    ServerProfile? deleteAfter,
  }) async {
    if (target.id == _runtime.profile.id) {
      return (switchFailure: null, deleteFailure: null);
    }

    final failure = await verifyThenHandOver(
      target: target,
      lifecycle: _runtime.profileLifecycle,
      handOver: () async {
        final next = ProfileRuntime.create(
          profile: target,
          registry: widget.registry,
          prefs: widget.prefs,
        );
        final previous = _runtime;
        holder.runtime = next;
        next.startPolling();
        holder.attachTray();
        if (mounted) setState(() {});
        // Only now is the old graph safe to tear down.
        await previous.dispose();
      },
    );
    if (failure != null) {
      return (switchFailure: failure, deleteFailure: null);
    }

    if (widget.registry.setLastActive(target.id)) widget.registry.save();
    await windowManager.setTitle(target.windowTitle);

    if (deleteAfter != null && deleteAfter.id != target.id) {
      final result = await holder.runtime.profileDeleter.delete(deleteAfter);
      if (result.outcome != ProfileDeletionOutcome.deleted) {
        // The switch SUCCEEDED; only the follow-up delete failed. Report it as a
        // separate fact so the caller does not show a "could not switch" error.
        return (
          switchFailure: null,
          deleteFailure:
              'could not delete ${deleteAfter.name}: '
              '${result.skipped.join('; ')}',
        );
      }
      holder.runtime.profilesController.notifyRegistryChanged();
    }
    return (switchFailure: null, deleteFailure: null);
  }

  @override
  Widget build(BuildContext context) {
    final profile = _runtime.profile;
    return ProviderScope(
      // Changing the key rebuilds the container, disposing every provider bound
      // to the previous profile.
      key: ValueKey('profile-${profile.id}'),
      observers: const [SidebarLayoutPrefsObserver()],
      overrides: [
        controlClientProvider.overrideWithValue(_runtime.client),
        desktopControllerProvider.overrideWithValue(_runtime.controller),
        serverProfileProvider.overrideWithValue(profile),
        profileRegistryProvider.overrideWithValue(widget.registry),
        profilesControllerProvider.overrideWithValue(
          _runtime.profilesController,
        ),
        profileLifecycleProvider.overrideWithValue(_runtime.profileLifecycle),
        profileDeleterProvider.overrideWithValue(_runtime.profileDeleter),
        profileSwitcherProvider.overrideWithValue(switchTo),
        switcherProfilesProvider.overrideWithValue(_runtime.profilesController),
        // Per-profile pairing bearer so two profiles never clobber each other's
        // stored server (a shared bearer wedged the app into "Reconnecting").
        secureStorageProvider.overrideWithValue(
          defaultSecureStore(namespace: profile.secureStoreNamespace),
        ),
        serverConfigProvider.overrideWith((ref) => _runtime.configController),
        groupsControllerProvider.overrideWith(
          (ref) => _runtime.groupsController,
        ),
        keymapProvider.overrideWith((ref) => widget.keymapController),
        preferencesControllerProvider.overrideWith(
          (ref) => widget.preferencesController,
        ),
        recentModelsControllerProvider.overrideWith(
          (ref) => widget.recentModelsController,
        ),
        cachedCommandsControllerProvider.overrideWith(
          (ref) => widget.cachedCommandsController,
        ),
        // SPEC-message-navigator: hand the stored rail on/off + options to the shared
        // transcript providers (shared `ui/` cannot read `desktop/` prefs).
        messageNavigatorStyleProvider.overrideWith(
          (ref) => ref.watch(desktopNavigatorStyleProvider),
        ),
        railOptionsProvider.overrideWith(
          (ref) => ref.watch(desktopRailOptionsProvider),
        ),
      ],
      child: _DesktopApp(tray: widget.tray),
    );
  }
}
