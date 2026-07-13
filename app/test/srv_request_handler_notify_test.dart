import 'dart:async';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/store/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/router.dart';
import 'package:makit/notifications/notification_observer.dart';
import 'package:makit/notifications/notification_request.dart';
import 'package:makit/notifications/notification_service.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';
import 'package:makit/ui/widgets/srv_request_handler.dart';

/// Records `show` calls without touching the platform channel.
class _RecordingNotificationService extends NotificationService {
  _RecordingNotificationService({this.result = true});

  /// Value returned from [show] — set to `false` to simulate a notification
  /// that could not be displayed (no permission / dismissed / platform throw).
  final bool result;
  final List<({int id, String? category, String? payload})> shown = [];

  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? category,
  }) async {
    shown.add((id: id, category: category, payload: payload));
    return result;
  }
}

/// Transport whose inbound frames the test drives directly.
class _EmittingTransport implements Transport {
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();

  void emit(Envelope env) => _frames.add(env);

  @override
  Future<void> connect(
    String url, {
    Map<String, dynamic> helloBody = const {},
    String? pinnedFingerprint,
  }) async {
    _state.add(WsState.connected);
  }

  @override
  Future<void> close() async {}

  @override
  Stream<Envelope> get frames => _frames.stream;

  @override
  Stream<WsState> get state => _state.stream;

  @override
  void sendEnvelope(Envelope env) {}

  @override
  void forceReconnect() {}
}

class _FakeSecureStorage implements SecureStore {
  _FakeSecureStorage(this._data);
  final Map<String, String> _data;

  @override
  Future<String?> read({required String key}) async => _data[key];

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

const _fingerprint =
    'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

_FakeSecureStorage _seeded() => _FakeSecureStorage({
  'paired_server': jsonEncode({
    'host': '192.168.1.10',
    'port': 8443,
    'fingerprint': _fingerprint,
    'bearer': 'b',
    'label': 'desktop',
  }),
});

void main() {
  Future<
    (_EmittingTransport, _RecordingNotificationService, ConnectionController)
  >
  pumpHandler(
    WidgetTester tester, {
    _RecordingNotificationService? notifications,
    GlobalKey<NavigatorState>? navigatorKey,
    Duration? reminderDelay,
  }) async {
    final transport = _EmittingTransport();
    final service = notifications ?? _RecordingNotificationService();
    final controller = ConnectionController(
      _seeded(),
      transportFactory: () => transport,
      browseLan: ({Duration timeout = const Duration(seconds: 3)}) async =>
          const [],
      rediscoverStall: Duration.zero,
    );

    final key = navigatorKey ?? makitNavigatorKey;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionControllerProvider.overrideWith((ref) => controller),
          notificationServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          navigatorKey: key,
          home: SrvRequestHandler(
            navigatorKey: key,
            reminderDelay: reminderDelay,
            child: const Scaffold(body: SizedBox()),
          ),
        ),
      ),
    );
    // Let _boot connect and the post-frame subscription attach.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    // Note: the ProviderScope owns the overridden controller and disposes it
    // on teardown — do NOT addTearDown(controller.dispose) (double dispose).
    return (transport, service, controller);
  }

  testWidgets(
    'backgrounded confirmAction fires a categorized notification, no dialog',
    (tester) async {
      final (transport, notifications, _) = await pumpHandler(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      transport.emit(
        Envelope(
          t: MsgType.srvRequest,
          id: 'req-1',
          body: {
            'kind': 'confirmAction',
            'action': 'rm -rf build/',
            'sessionId': 's1',
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(notifications.shown, hasLength(1));
      expect(notifications.shown.single.category, kConfirmCategoryId);
      final payload = parseNotificationPayload(
        notifications.shown.single.payload,
      );
      expect(payload.requestId, 'req-1');
      expect(payload.sessionId, 's1');
      expect(payload.kind, 'confirmAction');
      expect(find.text('Approve'), findsNothing);
    },
  );

  testWidgets('foreground confirmAction shows a dialog, no notification', (
    tester,
  ) async {
    final (transport, notifications, _) = await pumpHandler(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    transport.emit(
      Envelope(
        t: MsgType.srvRequest,
        id: 'req-2',
        body: {
          'kind': 'confirmAction',
          'action': 'rm -rf build/',
          'sessionId': 's1',
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(notifications.shown, isEmpty);
    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets('uses the navigator key supplied by the desktop app', (
    tester,
  ) async {
    final desktopNavigatorKey = GlobalKey<NavigatorState>();
    final (transport, notifications, _) = await pumpHandler(
      tester,
      navigatorKey: desktopNavigatorKey,
    );

    transport.emit(
      Envelope(
        t: MsgType.srvRequest,
        id: 'req-desktop',
        body: {
          'kind': 'confirmAction',
          'title': 'Desktop approval',
          'sessionId': 's1',
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(notifications.shown, isEmpty);
    expect(find.text('Desktop approval'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets(
    'backgrounded askUserQuestion fires a question notification, no dialog',
    (tester) async {
      final (transport, notifications, _) = await pumpHandler(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      transport.emit(
        Envelope(
          t: MsgType.srvRequest,
          id: 'req-q',
          body: {
            'kind': 'askUserQuestion',
            'question': 'Deploy to prod?',
            'sessionId': 's1',
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(notifications.shown, hasLength(1));
      expect(notifications.shown.single.category, kQuestionCategoryId);
      final payload = parseNotificationPayload(
        notifications.shown.single.payload,
      );
      expect(payload.requestId, 'req-q');
      expect(payload.kind, 'askUserQuestion');
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'backgrounded confirmAction falls back to a dialog when show returns false',
    (tester) async {
      final (transport, notifications, _) = await pumpHandler(
        tester,
        notifications: _RecordingNotificationService(result: false),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      transport.emit(
        Envelope(
          t: MsgType.srvRequest,
          id: 'req-fb',
          body: {
            'kind': 'confirmAction',
            'action': 'rm -rf build/',
            'sessionId': 's1',
          },
        ),
      );
      // Drain the async dispatch (emit → show → fallthrough → showDialog).
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // show() was attempted but returned false, so the dialog is presented
      // instead so the request stays answerable. The route is pushed while
      // backgrounded; resuming lets its entrance animation settle so it's
      // visible.
      expect(notifications.shown, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Approve'), findsOneWidget);
    },
  );

  testWidgets('backgrounded confirmAction is replayed as a dialog on resume', (
    tester,
  ) async {
    final (transport, notifications, _) = await pumpHandler(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    transport.emit(
      Envelope(
        t: MsgType.srvRequest,
        id: 'req-replay',
        body: {
          'kind': 'confirmAction',
          'action': 'rm -rf build/',
          'sessionId': 's1',
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    // Notification shown, dialog withheld while backgrounded.
    expect(notifications.shown, hasLength(1));
    expect(find.text('Approve'), findsNothing);

    // Resume and pump past the drain delay → dialog now presented.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets(
    'answered-from-notification request is not double-prompted on resume',
    (tester) async {
      final (transport, notifications, controller) = await pumpHandler(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      transport.emit(
        Envelope(
          t: MsgType.srvRequest,
          id: 'req-answered',
          body: {
            'kind': 'confirmAction',
            'action': 'rm -rf build/',
            'sessionId': 's1',
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(notifications.shown, hasLength(1));

      // The notification action answered the request (emits `responded`).
      controller.respondTo('req-answered', {
        'kind': 'confirmAction',
        'approved': true,
      });
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.text('Approve'), findsNothing);
    },
  );

  testWidgets(
    'notification id is deterministic per requestId and differs across requests',
    (tester) async {
      final (transport, notifications, _) = await pumpHandler(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      Envelope confirm(String id) => Envelope(
        t: MsgType.srvRequest,
        id: id,
        body: {
          'kind': 'confirmAction',
          'action': 'rm -rf build/',
          'sessionId': 's1',
        },
      );

      // Same env.id dispatched twice → same notification id (OS dedup).
      transport.emit(confirm('req-same'));
      await tester.pump();
      await tester.pump();
      transport.emit(confirm('req-same'));
      await tester.pump();
      await tester.pump();

      // Different env.id → different notification id.
      transport.emit(confirm('req-other'));
      await tester.pump();
      await tester.pump();

      expect(notifications.shown, hasLength(3));
      final firstId = notifications.shown[0].id;
      final secondId = notifications.shown[1].id;
      final otherId = notifications.shown[2].id;
      expect(secondId, firstId);
      expect(otherId, isNot(firstId));
    },
  );

  testWidgets(
    'desktop mode shows the dialog immediately even when backgrounded',
    (tester) async {
      final (transport, notifications, _) = await pumpHandler(
        tester,
        reminderDelay: const Duration(minutes: 2),
      );
      // Not frontmost (as a macOS window often is while the agent runs).
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      transport.emit(
        Envelope(
          t: MsgType.srvRequest,
          id: 'req-desk-q',
          body: {
            'kind': 'askUserQuestion',
            'question': 'Deploy to prod?',
            'options': [
              {'label': 'Yes'},
              {'label': 'No'},
            ],
            'sessionId': 's1',
          },
        ),
      );
      await tester.pump();
      await tester.pump();

      // No diversion to a notification while backgrounded — the dialog route
      // is pushed instead. Settle its entrance animation to confirm it shows.
      expect(notifications.shown, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Deploy to prod?'), findsOneWidget);
      expect(notifications.shown, isEmpty);
    },
  );

  testWidgets(
    'desktop mode fires a reminder notification only if left unanswered',
    (tester) async {
      final (transport, notifications, _) = await pumpHandler(
        tester,
        reminderDelay: const Duration(minutes: 2),
      );

      transport.emit(
        Envelope(
          t: MsgType.srvRequest,
          id: 'req-remind',
          body: {
            'kind': 'confirmAction',
            'action': 'rm -rf build/',
            'sessionId': 's1',
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Approve'), findsOneWidget);
      expect(notifications.shown, isEmpty);

      // Past the reminder delay while still unanswered → notification fires.
      await tester.pump(const Duration(minutes: 2));
      await tester.pump();
      expect(notifications.shown, hasLength(1));
      expect(notifications.shown.single.category, kConfirmCategoryId);
    },
  );

  testWidgets('desktop reminder is cancelled once the request is answered', (
    tester,
  ) async {
    final (transport, notifications, controller) = await pumpHandler(
      tester,
      reminderDelay: const Duration(minutes: 2),
    );

    transport.emit(
      Envelope(
        t: MsgType.srvRequest,
        id: 'req-answered-fast',
        body: {
          'kind': 'confirmAction',
          'action': 'rm -rf build/',
          'sessionId': 's1',
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    // Answered before the delay elapses.
    controller.respondTo('req-answered-fast', {
      'kind': 'confirmAction',
      'approved': true,
    });
    await tester.pump();

    // No reminder should fire after the delay.
    await tester.pump(const Duration(minutes: 2));
    await tester.pump();
    expect(notifications.shown, isEmpty);
  });
}
