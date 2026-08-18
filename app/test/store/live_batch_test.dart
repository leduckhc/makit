// One turn must not cost one store update per token.
//
// The server fans out one `session.event` frame per streamed token. The store
// now collects those frames and applies them in one batch per window, so the
// transcript folds once per window instead of once per token.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/event_batcher.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

class _Transport implements Transport {
  final sent = <Envelope>[];
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();

  void pushEvent(
    int seq, {
    String kind = 'agent.message.delta',
    Map<String, dynamic>? payload,
  }) {
    _frames.add(
      Envelope(
        t: MsgType.event,
        id: 'ev-$seq',
        body: {
          'kind': 'session.event',
          'event': {
            'seq': seq,
            'sessionId': 's1',
            'ts': 1700000000000 + seq,
            'kind': kind,
            'payload': payload ?? {'msgId': 'm1', 'chunk': 'x$seq'},
          },
        },
      ),
    );
  }

  void pushSnapshot({String status = 'running'}) {
    _frames.add(
      Envelope(
        t: MsgType.event,
        id: 'snap-1',
        body: {
          'kind': 'sessions.snapshot',
          'sessions': [
            {
              'id': 's1',
              'projectId': 'p1',
              'agent': 'pi',
              'title': 'session',
              'status': status,
              'policy': 'ask-on-risky',
              'createdAt': 1700000000000,
              'lastActivityAt': 1700000000000,
              'lastPreview': '',
            },
          ],
        },
      ),
    );
  }

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

/// A hand-run window, so the test decides when a batch lands.
class _Clock {
  void Function()? pending;
  ScheduledFlush schedule(Duration d, void Function() fn) {
    pending = fn;
    return ScheduledFlush(cancel: () => pending = null);
  }

  void fire() {
    final fn = pending;
    pending = null;
    fn?.call();
  }
}

void main() {
  ProviderContainer containerFor(_Transport transport, _Clock clock) {
    final container = ProviderContainer(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(
            _Storage({
              'paired_server': jsonEncode({
                'host': '192.168.1.10',
                'port': 8443,
                'fingerprint': 'f' * 64,
                'bearer': 'b',
                'label': 'desktop',
              }),
            }),
            transportFactory: () => transport,
            browseLan:
                ({Duration timeout = const Duration(seconds: 3)}) async =>
                    const [],
            rediscoverStall: const Duration(seconds: 30),
          ),
        ),
        storeControllerProvider.overrideWith(
          (ref) => StoreController(ref, batchSchedule: clock.schedule),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a burst of live events produces ONE store update', () async {
    final transport = _Transport();
    final clock = _Clock();
    final container = containerFor(transport, clock);
    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    var updates = 0;
    store.addListener((_) => updates++, fireImmediately: false);

    for (var seq = 1; seq <= 20; seq++) {
      transport.pushEvent(seq);
    }
    await Future<void>.delayed(Duration.zero);

    expect(updates, 0, reason: 'nothing applies before the window closes');
    clock.fire();

    expect(updates, 1, reason: '20 tokens, one update');
    expect(store.state.events['s1']!.length, 20);
    expect(store.state.cursors['s1'], 20);
  });

  test('a non-event frame applies the pending batch first', () async {
    final transport = _Transport();
    final clock = _Clock();
    final container = containerFor(transport, clock);
    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    transport.pushEvent(1);
    transport.pushSnapshot();
    await Future<void>.delayed(Duration.zero);

    expect(
      store.state.events['s1'],
      isNotNull,
      reason: 'the batch must not sit behind a later frame',
    );
    expect(store.state.sessions.single.id, 's1');
  });

  test('the optimistic user bubble sees the pending events', () async {
    final transport = _Transport();
    final clock = _Clock();
    final container = containerFor(transport, clock);
    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    transport.pushSnapshot(status: 'idle');
    await Future<void>.delayed(Duration.zero);
    transport.pushEvent(1);
    transport.pushEvent(2);
    transport.pushEvent(3);
    await Future<void>.delayed(Duration.zero);

    store.appendOptimisticMessage('s1', 'hello');

    final events = store.state.events['s1']!;
    expect(events.map((e) => e.seq), [
      1,
      2,
      3,
      4,
    ], reason: 'the bubble takes the seq after the pending ones, not after 0');
    expect(events.last.kind, EventKind.userMessage);
  });

  test('switching server drops events buffered for the old one', () async {
    final transport = _Transport();
    final clock = _Clock();
    final container = containerFor(transport, clock);
    final store = container.read(storeControllerProvider.notifier);
    await Future<void>.delayed(Duration.zero);

    transport.pushEvent(1);
    await Future<void>.delayed(Duration.zero);
    // Simulate the identity change the connection controller reports.
    await container.read(connectionControllerProvider.notifier).unpair();
    await Future<void>.delayed(Duration.zero);
    clock.fire();

    expect(store.state.events, isEmpty);
  });
}
