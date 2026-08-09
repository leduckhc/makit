import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

/// SPEC-47 D15: the server clock is the only clock. The store keeps a single
/// [serverClockOffset] updated from the `ts` of each **live** event and never
/// from replayed history.

class _Transport implements Transport {
  final sent = <Envelope>[];
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();

  void pushEvent(int seq, int ts) {
    _frames.add(
      Envelope(
        t: MsgType.event,
        id: 'ev-$seq',
        body: {
          'kind': 'session.event',
          'event': {
            'seq': seq,
            'sessionId': 's1',
            'ts': ts,
            'kind': 'agent.message',
            'payload': {'text': 'm$seq'},
          },
        },
      ),
    );
  }

  void pushAck(String id) => _frames.add(Envelope(t: MsgType.ack, id: id));

  @override
  Future<void> connect(
    String url, {
    Map<String, dynamic> helloBody = const {},
    String? pinnedFingerprint,
  }) async => _state.add(WsState.connected);

  @override
  Future<void> close() async {}

  @override
  Stream<Envelope> get frames => _frames.stream;

  @override
  Stream<WsState> get state => _state.stream;

  @override
  void sendEnvelope(Envelope env) => sent.add(env);

  @override
  void forceReconnect() {}
}

class _Storage implements SecureStore {
  _Storage(this.data);
  final Map<String, String> data;
  @override
  Future<String?> read({required String key}) async => data[key];
  @override
  Future<void> write({required String key, required String? value}) async =>
      value == null ? data.remove(key) : data[key] = value;
  @override
  Future<void> delete({required String key}) async => data.remove(key);
}

void main() {
  const deviceNow = 1_000_000;

  Map<String, dynamic> serverJson({
    required String fingerprint,
    required String host,
    required String label,
  }) => {
    'host': host,
    'port': 8443,
    'fingerprint': fingerprint,
    'bearer': 'b',
    'label': label,
  };

  ProviderContainer containerFor(
    _Transport transport, {
    Map<String, String>? storageData,
  }) {
    final container = ProviderContainer(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(
            _Storage(
              storageData ??
                  {
                    'paired_server': jsonEncode(
                      serverJson(
                        fingerprint: 'f' * 64,
                        host: '192.168.1.10',
                        label: 'desktop',
                      ),
                    ),
                  },
            ),
            transportFactory: () => transport,
            browseLan:
                ({Duration timeout = const Duration(seconds: 3)}) async =>
                    const [],
            rediscoverStall: const Duration(seconds: 30),
          ),
        ),
        storeControllerProvider.overrideWith(
          (ref) => StoreController(ref, nowMs: () => deviceNow),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a live event advances the offset to (event.ts − device now)', () async {
    final transport = _Transport();
    final container = containerFor(transport);
    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    transport.pushEvent(1, deviceNow + 30000); // server is 30s ahead
    await Future<void>.delayed(Duration.zero);

    expect(store.serverClockOffset, 30000);
    expect(store.serverNowMs(), deviceNow + 30000);
  });

  test('switching active servers resets the clock offset', () async {
    final transport = _Transport();
    final fpA = 'a' * 64;
    final fpB = 'b' * 64;
    final container = containerFor(
      transport,
      storageData: {
        'paired_servers': jsonEncode({
          'servers': [
            serverJson(fingerprint: fpA, host: '192.168.1.10', label: 'A'),
            serverJson(fingerprint: fpB, host: '10.0.0.2', label: 'B'),
          ],
          'activeId': fpA,
        }),
      },
    );
    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    transport.pushEvent(1, deviceNow + 30000);
    await Future<void>.delayed(Duration.zero);
    expect(store.serverClockOffset, 30000);

    await container.read(connectionControllerProvider.notifier).switchTo(fpB);
    await Future<void>.delayed(Duration.zero);

    expect(store.serverClockOffset, 0);
    expect(store.serverNowMs(), deviceNow);
  });

  test('a replayed event does NOT advance the offset (D15)', () async {
    final transport = _Transport();
    final container = containerFor(transport);
    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    // Subscribe → arms full replay; the events that follow are buffered and
    // flushed on the ack, which must not touch the offset.
    store.subscribeSession('s1');
    await Future<void>.delayed(Duration.zero);
    transport.pushEvent(1, deviceNow + 999999);
    transport.pushEvent(2, deviceNow + 999999);
    transport.pushAck('s-s1');
    await Future<void>.delayed(Duration.zero);

    expect(
      store.serverClockOffset,
      0,
      reason: 'replay must not move the clock',
    );
  });

  test(
    'history-loaded flips true after a full replay completes (D16)',
    () async {
      final transport = _Transport();
      final container = containerFor(transport);
      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(sessionHistoryLoadedProvider('s1')), isFalse);

      store.subscribeSession('s1');
      await Future<void>.delayed(Duration.zero);
      transport.pushEvent(1, deviceNow);
      transport.pushAck('s-s1');
      await Future<void>.delayed(Duration.zero);

      expect(container.read(sessionHistoryLoadedProvider('s1')), isTrue);
    },
  );
}
