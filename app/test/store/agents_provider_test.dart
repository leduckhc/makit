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

/// In-memory secure store seeded with a paired server so the controller's boot
/// path attaches the (fake) transport.
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

/// A transport that stays disconnected until [connectNow] is called, and
/// answers `agents.list` with a canned harness so we can observe the fetch.
class _FakeTransport implements Transport {
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();
  int agentsListRequests = 0;
  bool _connected = false;

  void connectNow() {
    _connected = true;
    _state.add(WsState.connected);
  }

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
    // A dead socket drops sends; only answer once connected (mirrors reality).
    if (!_connected) return;
    if (env.t == MsgType.cmd && env.body['kind'] == 'agents.list') {
      agentsListRequests++;
      _frames.add(
        Envelope(
          t: MsgType.ack,
          id: env.id,
          body: const {
            'agents': [
              {
                'id': 'pi',
                'label': 'Pi (native)',
                'transport': 'native',
                'available': true,
              },
            ],
          },
        ),
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

void main() {
  // Regression (SPEC-20 boot restore): a persisted worktree can build the
  // harness picker BEFORE the socket connects. `agentsProvider` used to fetch
  // eagerly and cache the swallowed-empty result forever, so every worktree
  // stayed on the "host default harness" fallback. It must stay loading while
  // disconnected and (re)fetch once the socket connects.
  test(
    'agentsProvider waits for the socket, then fetches the harness list',
    () async {
      final transport = _FakeTransport();
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(
              _FakeSecureStorage({
                _kPairedServerKey: jsonEncode({
                  'host': '127.0.0.1',
                  'port': 8787,
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
      addTearDown(container.dispose);

      // Drive off real state transitions instead of fixed sleeps (which race on
      // slow CI): resolve a completer the moment the provider yields agents.
      final resolved = Completer<List<AgentDescriptor>>();
      container.listen<AsyncValue<List<AgentDescriptor>>>(agentsProvider, (
        _,
        next,
      ) {
        if (next.hasValue && !resolved.isCompleted) {
          resolved.complete(next.value);
        }
      }, fireImmediately: true);
      // Let boot attach the (still-disconnected) transport.
      await Future<void>.delayed(Duration.zero);

      // Disconnected: no eager fetch, still loading (never a cached empty list).
      expect(transport.agentsListRequests, 0);
      expect(
        container.read(agentsProvider),
        isA<AsyncLoading<List<AgentDescriptor>>>(),
      );
      expect(resolved.isCompleted, isFalse);

      // Socket comes up → the provider re-runs and fetches for real. Await the
      // resolved-agents transition rather than a fixed delay.
      transport.connectNow();
      final agents = await resolved.future.timeout(const Duration(seconds: 5));

      expect(transport.agentsListRequests, 1);
      expect(agents.single.id, 'pi');
    },
  );
}
