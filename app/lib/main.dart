import 'dart:async';
import 'dart:io' show Platform;

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
import 'store/store.dart';
import 'transport/transport.dart';
import 'ui/widgets/makit_mark.dart';
import 'ui/widgets/srv_request_handler.dart';
import 'desktop/desktop_app.dart';
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
    ],
  );
  container.read(storeControllerProvider);

  // Notifications: route taps into the session and activate the status→notif
  // observer. onTapSession + the controller are cheap (no platform calls yet).
  final notifications = container.read(notificationServiceProvider);
  notifications.onTapSession = (payload) {
    final sid = parseNotificationPayload(payload).sessionId;
    if (sid != null && sid.isNotEmpty) {
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
  // Both branches currently build the mobile router: Lane 3 lands the
  // desktop-style `WorkspaceView` and swaps it into `workspaceBuilder`. Until
  // then iPad keeps working on the existing UI (plan: "before Lane 3 it simply
  // routes iPad to the current pane UI").
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: PlatformShell(
        workspaceBuilder: (_) => const MakitApp(),
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
