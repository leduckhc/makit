import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

const _kPairedServerKey = 'paired_server';
const _fingerprint =
    'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';

class _FakeSecureStorage implements SecureStore {
  _FakeSecureStorage([Map<String, String>? seed]) : data = {...?seed};
  final Map<String, String> data;
  @override
  Future<String?> read({required String key}) async => data[key];
  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({required String key}) async => data.remove(key);
}

/// Captures `session.spawn` frames and acks them with a canned session id so
/// the test can assert on exactly what the store put on the wire.
class _CapturingTransport implements Transport {
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();
  final List<Map<String, dynamic>> spawnBodies = [];

  void connectNow() => _state.add(WsState.connected);

  @override
  Future<void> connect(
    String url, {
    Map<String, dynamic> helloBody = const {},
    String? pinnedFingerprint,
  }) async {
    _state.add(WsState.connecting);
  }

  @override
  void sendEnvelope(Envelope env) {
    if (env.t == MsgType.cmd && env.body['kind'] == 'session.spawn') {
      spawnBodies.add(env.body);
      _frames.add(
        Envelope(t: MsgType.ack, id: env.id, body: const {'sessionId': 's-1'}),
      );
    }
  }

  @override
  Future<void> close() async {}
  @override
  Stream<Envelope> get frames => _frames.stream;
  @override
  Stream<WsState> get state => _state.stream;
  @override
  void forceReconnect() {}
}

ProviderContainer _makeContainer(_CapturingTransport transport) {
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(
          _FakeSecureStorage({
            _kPairedServerKey: jsonEncode({
              'host': '127.0.0.1',
              'port': 7788,
              'fingerprint': _fingerprint,
              'bearer': 'b',
              'label': 'desktop',
            }),
          }),
          transportFactory: () => transport,
          rediscoverStall: const Duration(hours: 1),
        ),
      ),
    ],
  );
  return container;
}

/// Boot the controller (attaches the fake transport), bring the socket up, and
/// wait until the store observes the `connected` state so `request` won't drop
/// its send on an unattached socket.
Future<StoreController> _connectedStore(
  ProviderContainer container,
  _CapturingTransport transport,
) async {
  final connected = Completer<void>();
  container.listen<MakitConnState>(connectionControllerProvider, (_, next) {
    if (next.wsState == WsState.connected && !connected.isCompleted) {
      connected.complete();
    }
  }, fireImmediately: true);
  // Let boot read the paired server and attach the transport.
  await Future<void>.delayed(Duration.zero);
  transport.connectNow();
  await connected.future.timeout(const Duration(seconds: 5));
  return container.read(storeControllerProvider.notifier);
}

void main() {
  group('StoreController.spawnSession configOptions picks', () {
    test('forwards picks in the session.spawn envelope', () async {
      final transport = _CapturingTransport();
      final container = _makeContainer(transport);
      addTearDown(container.dispose);
      final store = await _connectedStore(container, transport);

      final sid = await store.spawnSession(
        'proj-1',
        agent: 'pi',
        worktreePath: '/wt',
        configOptions: const [
          ConfigOptionPick(id: 'model', value: 'gpt-5'),
          ConfigOptionPick(id: 'yolo', value: true),
        ],
      );

      expect(sid, 's-1');
      final body = transport.spawnBodies.single;
      expect(body['kind'], 'session.spawn');
      expect(body['projectId'], 'proj-1');
      expect(body['agent'], 'pi');
      expect(body['configOptions'], [
        {'id': 'model', 'value': 'gpt-5'},
        {'id': 'yolo', 'value': true},
      ]);
    });

    test('omits configOptions when no picks are given', () async {
      final transport = _CapturingTransport();
      final container = _makeContainer(transport);
      addTearDown(container.dispose);
      final store = await _connectedStore(container, transport);

      await store.spawnSession('proj-1', agent: 'pi');

      final body = transport.spawnBodies.single;
      expect(body.containsKey('configOptions'), isFalse);
    });

    test('omits configOptions when the picks list is empty', () async {
      final transport = _CapturingTransport();
      final container = _makeContainer(transport);
      addTearDown(container.dispose);
      final store = await _connectedStore(container, transport);

      await store.spawnSession('proj-1', agent: 'pi', configOptions: const []);

      final body = transport.spawnBodies.single;
      expect(body.containsKey('configOptions'), isFalse);
    });
  });
}
