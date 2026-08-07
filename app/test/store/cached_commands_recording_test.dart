/// SPEC-45 D4 — the store records what a live session advertises into the
/// per-(agent, project) command cache, so the sessionless starter pane can
/// offer that palette. Recorded on the `session.commands` event itself, never
/// diffed out of the state, so a streamed turn does not pay for it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/cached_commands.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

class _Storage implements SecureStore {
  _Storage(this.data);
  final Map<String, String> data;
  @override
  Future<String?> read({required String key}) async => data[key];
  @override
  Future<void> write({required String key, required String? value}) async =>
      data[key] = value ?? '';
  @override
  Future<void> delete({required String key}) async => data.remove(key);
}

class _Transport implements Transport {
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();

  void pushSessions(List<Map<String, dynamic>> sessions) => _frames.add(
    Envelope(
      t: MsgType.event,
      id: 'snap',
      body: {'kind': 'sessions.snapshot', 'sessions': sessions},
    ),
  );

  void pushCommands({
    required String sessionId,
    required int seq,
    required List<Map<String, dynamic>> commands,
  }) => _frames.add(
    Envelope(
      t: MsgType.event,
      id: 'ev-$seq',
      body: {
        'kind': 'session.event',
        'event': {
          'seq': seq,
          'sessionId': sessionId,
          'ts': seq * 1000,
          'kind': 'session.commands',
          'payload': {'commands': commands},
        },
      },
    ),
  );

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
  void sendEnvelope(Envelope env) {}
  @override
  void forceReconnect() {}
}

Map<String, dynamic> _session({
  String id = 's1',
  String agent = 'zed',
  String projectId = 'p1',
}) => {
  'id': id,
  'projectId': projectId,
  'agent': agent,
  'title': 't',
  'status': 'idle',
  'policy': 'ask',
};

({ProviderContainer container, _Transport transport}) _boot() {
  final transport = _Transport();
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
          browseLan: ({Duration timeout = const Duration(seconds: 3)}) async =>
              const [],
          rediscoverStall: const Duration(seconds: 30),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(storeControllerProvider.notifier);
  return (container: container, transport: transport);
}

void main() {
  test(
    'session.commands is cached under the session agent + project',
    () async {
      final h = _boot();
      await Future<void>.delayed(Duration.zero);

      h.transport.pushSessions([_session()]);
      h.transport.pushCommands(
        sessionId: 's1',
        seq: 1,
        commands: [
          {
            'name': 'skill:dart-add-unit-test',
            'description': 'Write unit tests',
            'source': 'skill',
            'location': 'project',
          },
        ],
      );
      await Future<void>.delayed(Duration.zero);

      final cache = h.container.read(cachedCommandsControllerProvider.notifier);
      expect(cache.commandsFor('zed', 'p1').map((c) => c.name), [
        'skill:dart-add-unit-test',
      ]);
    },
  );

  test('commands for an unknown session are not cached', () async {
    final h = _boot();
    await Future<void>.delayed(Duration.zero);

    // No sessions snapshot: there is no agent/project to key the palette by, so
    // it must be dropped rather than guessed at.
    h.transport.pushCommands(
      sessionId: 'ghost',
      seq: 1,
      commands: [
        {'name': 'x', 'description': '', 'source': 'prompt'},
      ],
    );
    await Future<void>.delayed(Duration.zero);

    expect(h.container.read(cachedCommandsControllerProvider), isEmpty);
  });

  test('a non-commands event caches nothing', () async {
    final h = _boot();
    await Future<void>.delayed(Duration.zero);

    h.transport.pushSessions([_session()]);
    h.transport._frames.add(
      Envelope(
        t: MsgType.event,
        id: 'ev-1',
        body: {
          'kind': 'session.event',
          'event': {
            'seq': 1,
            'sessionId': 's1',
            'ts': 1,
            'kind': 'agent.message',
            'payload': {'text': 'hello'},
          },
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(h.container.read(cachedCommandsControllerProvider), isEmpty);
  });
}
