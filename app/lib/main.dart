import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'app/test_bootstrap.dart';
import 'notifications/notification_observer.dart';
import 'notifications/notification_request.dart';
import 'store/connection.dart';
import 'store/store.dart';
import 'ui/widgets/pino_mark.dart';
import 'ui/widgets/srv_request_handler.dart';
import 'desktop/desktop_app.dart';

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
  final container = ProviderContainer();
  container.read(storeControllerProvider);

  // Notifications: route taps into the session and activate the status→notif
  // observer. onTapSession + the controller are cheap (no platform calls yet).
  final notifications = container.read(notificationServiceProvider);
  notifications.onTapSession = (payload) {
    final sid = parseNotificationPayload(payload).sessionId;
    if (sid != null && sid.isNotEmpty) {
      pinoNavigatorKey.currentContext?.go('/session/$sid');
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

  runApp(
    UncontrolledProviderScope(container: container, child: const PinoApp()),
  );

  // Init the plugin AFTER the first frame so startup isn't blocked, and skip
  // it under the E2E harness — the iOS permission prompt blocks the simulator
  // and would stop runApp's UI from ever being reached.
  if (!isE2ETestMode) {
    unawaited(notifications.init());
  }
}

class PinoApp extends ConsumerStatefulWidget {
  const PinoApp({super.key});

  @override
  ConsumerState<PinoApp> createState() => _PinoAppState();
}

class _PinoAppState extends ConsumerState<PinoApp> with WidgetsBindingObserver {
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
        theme: pinoDarkTheme,
        home: PinoSplash(
          onCompleted: () {
            if (mounted) setState(() => _showSplash = false);
          },
        ),
      );
    }
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'pino',
      theme: pinoLightTheme,
      darkTheme: pinoDarkTheme,
      themeMode: ThemeMode.system,
      routerConfig: router,
      builder: (context, child) =>
          SrvRequestHandler(child: child ?? const SizedBox()),
      debugShowCheckedModeBanner: false,
    );
  }
}
