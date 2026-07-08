import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/store/connection.dart';
import 'package:pino/store/models.dart';
import 'package:pino/store/store.dart';
import 'package:pino/transport/codec.dart';
import 'package:pino/transport/protocol.dart';
import 'package:pino/transport/transport.dart';

const _sid = 's1';

SessionEvent _ev(int seq, EventKind kind, Map<String, dynamic> payload) =>
    SessionEvent(
      seq: seq,
      sessionId: _sid,
      ts: seq * 1000,
      kind: kind,
      payload: payload,
    );

StoreState _seeded() => StoreState.empty().copyWith(
  sessions: [
    Session(
      id: _sid,
      projectId: 'p1',
      agent: 'pi',
      title: 't',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
    ),
  ],
);

void main() {
  group('reduce — seq-cursor idempotency (B4)', () {
    test(
      'optimistic user bubble (seq N) + server echo (seq N) → ONE bubble',
      () {
        var state = _seeded();
        // Optimistic append: takes seq = cursor + 1 = 1.
        state = reduceEvent(
          state,
          _ev(1, EventKind.userMessage, {'text': 'hi'}),
        );
        // Server echoes the same message with the SAME seq.
        state = reduce(
          state,
          SessionEventFrame(_ev(1, EventKind.userMessage, {'text': 'hi'})),
        );

        final items = foldEvents(
          state.events[_sid]!,
        ).whereType<UserMessageItem>().toList();
        expect(items.length, 1);
        expect(items.single.text, 'hi');
        expect(state.cursors[_sid], 1);
      },
    );

    test('duplicate and older seqs are dropped', () {
      var state = _seeded();
      state = reduceEvent(state, _ev(1, EventKind.userMessage, {'text': 'a'}));
      state = reduceEvent(state, _ev(2, EventKind.agentMessage, {'text': 'b'}));
      // Duplicate (seq 2) and older (seq 1) must be dropped.
      state = reduceEvent(
        state,
        _ev(2, EventKind.agentMessage, {'text': 'dup'}),
      );
      state = reduceEvent(
        state,
        _ev(1, EventKind.userMessage, {'text': 'old'}),
      );

      expect(state.events[_sid]!.length, 2);
      expect(state.cursors[_sid], 2);
    });

    test('session.commands advances cursor but adds no chat item', () {
      var state = _seeded();
      state = reduce(
        state,
        SessionEventFrame(
          _ev(1, EventKind.sessionCommands, {
            'commands': [
              {'name': 'fix', 'description': 'd', 'source': 'prompt'},
            ],
          }),
        ),
      );

      expect(state.cursors[_sid], 1);
      expect(state.events[_sid] ?? const [], isEmpty);
      expect(state.commands[_sid]!.length, 1);
      expect(state.commands[_sid]!.single.name, 'fix');
    });

    test('session.meta advances cursor, stores meta, adds no chat item', () {
      var state = _seeded();
      state = reduce(
        state,
        SessionEventFrame(
          _ev(1, EventKind.sessionMeta, {
            'model': {'provider': 'anthropic', 'id': 'opus', 'name': 'Opus'},
            'thinking': 'high',
            'models': [
              {'provider': 'anthropic', 'id': 'opus', 'name': 'Opus'},
              {'provider': 'anthropic', 'id': 'sonnet', 'name': 'Sonnet'},
            ],
          }),
        ),
      );

      expect(state.cursors[_sid], 1);
      expect(state.events[_sid] ?? const [], isEmpty);
      final meta = state.meta[_sid]!;
      expect(meta.model!.name, 'Opus');
      expect(meta.thinking, 'high');
      expect(meta.models.length, 2);
    });

    test(
      'session.action_error advances cursor, stores error, adds no chat item',
      () {
        var state = _seeded();
        state = reduce(
          state,
          SessionEventFrame(
            _ev(1, EventKind.sessionActionError, {
              'action': 'compact',
              'reason': 'session not ready',
            }),
          ),
        );

        expect(state.cursors[_sid], 1);
        expect(state.events[_sid] ?? const [], isEmpty);
        final err = state.actionErrors[_sid]!;
        expect(err.action, 'compact');
        expect(err.reason, 'session not ready');
        expect(err.seq, 1);
      },
    );

    test('session.status + message preview bubble up to the session', () {
      var state = _seeded();
      state = reduce(
        state,
        SessionEventFrame(
          _ev(1, EventKind.sessionStatus, {'status': 'running'}),
        ),
      );
      var session = state.sessions.single;
      expect(session.status, SessionStatus.running);
      // status events are not chat items.
      expect(foldEvents(state.events[_sid] ?? const []), isEmpty);

      state = reduce(
        state,
        SessionEventFrame(
          _ev(2, EventKind.agentMessage, {'text': 'working on it'}),
        ),
      );
      session = state.sessions.single;
      expect(session.lastPreview, 'working on it');
      expect(session.lastActivityAt, 2000);
    });
  });

  group('StoreController — sub carries fromSeq cursor', () {
    test('sub after seeing events replays only newer ones', () async {
      final transport = _CapturingTransport();
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(
              _FakeStorage({
                'paired_server': jsonEncode({
                  'host': '192.168.1.10',
                  'port': 8443,
                  'fingerprint': 'f' * 64,
                  'bearer': 'b',
                  'label': 'desktop',
                }),
              }),
              transportFactory: () => transport,
              browseLan: ({Duration timeout = const Duration(seconds: 3)}) async => const [],
              rediscoverStall: const Duration(seconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero); // let boot/connect settle

      // Server pushes an event at seq 7 → advances the client cursor.
      transport.pushEvent(seq: 7, sessionId: _sid);
      await Future<void>.delayed(Duration.zero);

      transport.sent.clear();
      store.subscribeSession(_sid);

      final sub = transport.sent.singleWhere((e) => e.t == MsgType.sub);
      expect(sub.body['sessionId'], _sid);
      expect(sub.body['fromSeq'], 7);
    });

    test('fresh sub with no events seen sends fromSeq 0', () async {
      final transport = _CapturingTransport();
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(
              _FakeStorage({
                'paired_server': jsonEncode({
                  'host': '192.168.1.10',
                  'port': 8443,
                  'fingerprint': 'f' * 64,
                  'bearer': 'b',
                  'label': 'desktop',
                }),
              }),
              transportFactory: () => transport,
              browseLan: ({Duration timeout = const Duration(seconds: 3)}) async => const [],
              rediscoverStall: const Duration(seconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      transport.sent.clear();
      store.subscribeSession(_sid);

      final sub = transport.sent.singleWhere((e) => e.t == MsgType.sub);
      expect(sub.body['fromSeq'], 0);
    });
  });
}

/// Transport fake that records outgoing envelopes and lets a test inject
/// inbound event frames. Emits `connected` on connect so the controller's
/// resubscribe-on-reconnect wiring is live.
class _CapturingTransport implements Transport {
  final sent = <Envelope>[];
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();

  void pushEvent({required int seq, required String sessionId}) {
    _frames.add(
      Envelope(
        t: MsgType.event,
        id: 'ev-$seq',
        body: {
          'kind': 'session.event',
          'event': {
            'seq': seq,
            'sessionId': sessionId,
            'ts': seq * 1000,
            'kind': 'agent.message',
            'payload': {'text': 'm$seq'},
          },
        },
      ),
    );
  }

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
  void sendEnvelope(Envelope env) => sent.add(env);

  @override
  void forceReconnect() {}
}

class _FakeStorage extends FlutterSecureStorage {
  _FakeStorage(this.data) : super();
  final Map<String, String> data;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data[key];

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
  }) async {
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => data.remove(key);
}
