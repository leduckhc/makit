import 'dart:async';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/app/router.dart';
import 'package:pino/notifications/notification_observer.dart';
import 'package:pino/notifications/notification_request.dart';
import 'package:pino/notifications/notification_service.dart';
import 'package:pino/store/connection.dart';
import 'package:pino/transport/protocol.dart';
import 'package:pino/transport/transport.dart';
import 'package:pino/ui/widgets/srv_request_handler.dart';

/// Records `show` calls without touching the platform channel.
class _RecordingNotificationService extends NotificationService {
  final List<({String? category, String? payload})> shown = [];

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? category,
  }) async {
    shown.add((category: category, payload: payload));
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

class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage(this._data) : super();
  final Map<String, String> _data;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
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
  Future<(_EmittingTransport, _RecordingNotificationService)> pumpHandler(
    WidgetTester tester,
  ) async {
    final transport = _EmittingTransport();
    final notifications = _RecordingNotificationService();
    final controller = ConnectionController(
      _seeded(),
      transportFactory: () => transport,
      browseLan:
          ({Duration timeout = const Duration(seconds: 3)}) async => const [],
      rediscoverStall: Duration.zero,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionControllerProvider.overrideWith((ref) => controller),
          notificationServiceProvider.overrideWithValue(notifications),
        ],
        child: MaterialApp(
          navigatorKey: pinoNavigatorKey,
          home: const SrvRequestHandler(child: Scaffold(body: SizedBox())),
        ),
      ),
    );
    // Let _boot connect and the post-frame subscription attach.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    // Note: the ProviderScope owns the overridden controller and disposes it
    // on teardown — do NOT addTearDown(controller.dispose) (double dispose).
    return (transport, notifications);
  }

  testWidgets(
    'backgrounded confirmAction fires a categorized notification, no dialog',
    (tester) async {
      final (transport, notifications) = await pumpHandler(tester);
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
    final (transport, notifications) = await pumpHandler(tester);
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
}
