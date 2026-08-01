import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'app/test_bootstrap.dart';
import 'notifications/notification_observer.dart';
import 'notifications/notification_request.dart';
import 'notifications/pending_action_drain.dart';
import 'notifications/push_registration.dart';
import 'store/connection.dart';
import 'store/recent_models.dart';
import 'store/store.dart';
import 'transport/transport.dart';
import 'ui/widgets/makit_mark.dart';
import 'ui/widgets/srv_request_handler.dart';
import 'desktop/desktop_app.dart';
import 'desktop/chat/desktop_chat_shell.dart';
import 'desktop/chat/keymap_scope.dart';
import 'desktop/chat/panes/workspace_controller.dart';
import 'platform_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // macOS is the server-side *control* app (SPEC-03), a different app from the
  // mobile client — it must never show the pairing/chat flow. Branch to its own
  // root before any mobile-only bootstrap runs.
  if (Platform.isMacOS) {
    await runDesktopApp();
    return;
  }

  await seedTestPairingIfRequested();
  // SPEC-31: load the persisted recent-model list before wiring the store so
  // the model picker's Recent section survives restarts on mobile too.
  final prefs = await SharedPreferences.getInstance();
  final recentModelsController = RecentModelsController.load(prefs);
  // The store listens to a broadcast stream that drops events without
  // listeners. Eagerly create the controller so it's subscribed before the
  // WS connects and starts pushing projects/sessions snapshots.
  //
  // SPEC-07: inject a channel-backed push registrar so the APNs token the iOS
  // `AppDelegate` forwards over `makit/push` reaches the controller, which then
  // sends `push.register`. Tests keep the default NoopPushRegistrar.
  final container = ProviderContainer(
    overrides: [
      pushRegistrarProvider.overrideWithValue(ChannelPushRegistrar()),
      recentModelsControllerProvider.overrideWith(
        (ref) => recentModelsController,
      ),
    ],
  );
  container.read(storeControllerProvider);

  // Notifications: route taps into the session and activate the status→notif
  // observer. onTapSession + the controller are cheap (no platform calls yet).
  final notifications = container.read(notificationServiceProvider);
  notifications.onTapSession = (payload) {
    final sid = parseNotificationPayload(payload).sessionId;
    if (sid == null || sid.isEmpty) return;
    // On the workspace shell (regular iPad) there is no go_router navigator to
    // receive the deep link, so reveal the session in the workspace controller
    // instead; the mobile router handles it via go() otherwise.
    if (_prefersWorkspaceShellNow()) {
      container.read(workspaceControllerProvider.notifier).revealSession(sid);
    } else {
      makitNavigatorKey.currentContext?.go('/session/$sid');
    }
  };
  // Actionable notifications (Approve/Deny/Reply) on the live isolate: map the
  // tapped action to a srv.response body and route it through respondTo
  // (idempotent, so the dialog path can't double-respond).
  notifications.onAction = (actionId, input, payload) {
    final p = parseNotificationPayload(payload);
    final rid = p.requestId;
    if (rid == null || p.kind == null) return;
    final body = responseForAction(
      kind: p.kind!,
      actionId: actionId,
      input: input,
    );
    if (body == null) return;
    container.read(connectionControllerProvider.notifier).respondTo(rid, body);
  };
  container.read(notificationControllerProvider);

  // SPEC-07: on every `wsState → connected` transition, drain the force-quit
  // pending-action queue (taps captured by the background isolate while the
  // app was dead) through the same responseForAction + respondTo path. Mirrors
  // store.dart's re-subscribe-on-reconnect listener. Idempotent via respondTo.
  container.listen<MakitConnState>(connectionControllerProvider, (prev, next) {
    final wasConnected = prev?.wsState == WsState.connected;
    final nowConnected = next.wsState == WsState.connected;
    if (!wasConnected && nowConnected) {
      unawaited(_drainPendingActions(container));
    }
  }, fireImmediately: false);

  // SPEC-28 (decision 10): iPadOS reaches the workspace shell by *size class*,
  // not just Platform — a full-screen (regular×regular) iPad routes to the
  // workspace, while iPhone / compact split-view iPads stay on the mobile
  // router. macOS never reaches here (it returned early via runDesktopApp
  // above), so its window_manager/daemon bootstrap stays guarded by
  // Platform.isMacOS and never runs on iPad.
  //
  // The workspace branch reuses the desktop `DesktopChatShell` (sidebar +
  // `WorkspaceView`) over the same store/connection the mobile bootstrap above
  // already set up. It intentionally omits macOS-only chrome: no daemon/tray,
  // no desktop Settings window (the sidebar's settings button is hidden), and
  // the workspace controller is the in-memory (non-persisted) default — layout
  // persistence there is only wired for macOS in runDesktopApp.
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: PlatformShell(
        workspaceBuilder: (_) => const _WorkspaceShellApp(),
        mobileBuilder: (_) => const MakitApp(),
      ),
    ),
  );

  // Init the plugin AFTER the first frame so startup isn't blocked, and skip
  // it under the E2E harness — the iOS permission prompt blocks the simulator
  // and would stop runApp's UI from ever being reached.
  if (!isE2ETestMode) {
    unawaited(notifications.init());
  }
}

/// Whether the app is currently on the workspace shell (macOS / regular iPad)
/// rather than the mobile router — computed from the implicit view's size class,
/// mirroring [PlatformShell]. Used off the widget tree (the notification tap
/// handler runs at bootstrap, with no [BuildContext]).
bool _prefersWorkspaceShellNow() {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) return false;
  return prefersWorkspaceShell(
    platform: defaultTargetPlatform,
    size: view.physicalSize / view.devicePixelRatio,
  );
}

/// SPEC-07: drain the persisted force-quit pending-action queue through
/// `respondTo` (idempotent). Best-effort — a failure never blocks startup.
Future<void> _drainPendingActions(ProviderContainer container) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final respond = container
        .read(connectionControllerProvider.notifier)
        .respondTo;
    await PendingActionDrainer(prefs, respond).drain();
  } catch (_) {
    // Best-effort: a failed drain must not crash the app.
  }
}

class MakitApp extends ConsumerStatefulWidget {
  const MakitApp({super.key});

  @override
  ConsumerState<MakitApp> createState() => _MakitAppState();
}

class _MakitAppState extends ConsumerState<MakitApp>
    with WidgetsBindingObserver {
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On foreground, nudge a stalled WS connection to reconnect immediately
    // instead of waiting out backoff (iOS suspends sockets/timers in the
    // background). No-op when already connected.
    if (state == AppLifecycleState.resumed) {
      ref.read(connectionControllerProvider.notifier).onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: makitDarkTheme,
        home: MakitSplash(
          onCompleted: () {
            if (mounted) setState(() => _showSplash = false);
          },
        ),
      );
    }
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'makit',
      theme: makitLightTheme,
      darkTheme: makitDarkTheme,
      themeMode: ThemeMode.system,
      routerConfig: router,
      builder: (context, child) =>
          SrvRequestHandler(child: child ?? const SizedBox()),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// SPEC-28 (decision 10): the iPad workspace app. A minimal [MaterialApp]
/// hosting the desktop [DesktopChatShell] (sidebar + `WorkspaceView`) over the
/// mobile bootstrap's store/connection, with the global keyboard shortcuts
/// installed. It deliberately omits the macOS-only Settings window (the
/// sidebar's settings button is hidden) and the daemon/tray glue; those live in
/// `runDesktopApp`. Layout persistence is macOS-only for now — the iPad uses the
/// in-memory workspace controller default.
class _WorkspaceShellApp extends StatelessWidget {
  const _WorkspaceShellApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'makit',
      theme: makitLightTheme,
      darkTheme: makitDarkTheme,
      themeMode: ThemeMode.system,
      debugShowCheckedModeBanner: false,
      builder: (context, child) =>
          SrvRequestHandler(child: child ?? const SizedBox()),
      home: DesktopKeymapScope(
        onOpenSettings: () {},
        child: const DesktopChatShell(),
      ),
    );
  }
}
