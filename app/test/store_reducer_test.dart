import 'dart:async';
import 'dart:convert';

import 'package:makit/store/secure_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/transport/transport.dart';

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

  group('reduce — github.budget', () {
    test('a budget frame updates githubBudget', () {
      final budget = GithubBudget.fromJson({
        'buckets': {
          'core': {'limit': 5000, 'remaining': 1769, 'resetAt': 1, 'mine': 1},
        },
        'burnPerHour': 340,
        'level': 'warm',
        'throttles': ['poll 30s'],
        'measuredAt': 2,
      });
      final state = reduce(StoreState.empty(), GithubBudgetFrame(budget));
      expect(state.githubBudget, isNotNull);
      expect(state.githubBudget!.level, BudgetLevel.warm);
      expect(state.githubBudget!.core!.remaining, 1769);
    });

    test('empty store has no budget yet (null)', () {
      expect(StoreState.empty().githubBudget, isNull);
    });
  });

  group('githubBudgetProvider', () {
    test('reads null before any budget frame arrives', () async {
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
              browseLan:
                  ({Duration timeout = const Duration(seconds: 3)}) async =>
                      const [],
              rediscoverStall: const Duration(seconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(githubBudgetProvider), isNull);
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
              browseLan:
                  ({Duration timeout = const Duration(seconds: 3)}) async =>
                      const [],
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
              browseLan:
                  ({Duration timeout = const Duration(seconds: 3)}) async =>
                      const [],
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

  group('StoreController — initial replay is applied in one batch', () {
    test(
      'replay events are buffered until the sub ack, then applied together',
      () async {
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
                browseLan:
                    ({Duration timeout = const Duration(seconds: 3)}) async =>
                        const [],
                rediscoverStall: const Duration(seconds: 30),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final store = container.read(storeControllerProvider.notifier);
        await Future<void>.delayed(Duration.zero);

        store.subscribeSession(_sid);
        await Future<void>.delayed(Duration.zero);

        // Replay events stream in one at a time — they must NOT be visible in
        // the store yet (no churn: the transcript stays empty until the batch).
        transport.pushEvent(seq: 1, sessionId: _sid);
        transport.pushEvent(seq: 2, sessionId: _sid);
        await Future<void>.delayed(Duration.zero);
        expect(
          container.read(storeControllerProvider).events[_sid] ?? const [],
          isEmpty,
        );

        // The sub ack (id 's-<sid>') closes replay → the buffer flushes in a
        // single state update, landing at the newest message.
        transport.pushAck(id: 's-$_sid');
        await Future<void>.delayed(Duration.zero);
        final state = container.read(storeControllerProvider);
        expect(state.events[_sid]!.length, 2);
        expect(state.cursors[_sid], 2);
      },
    );

    test('live events after the ack are applied immediately', () async {
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
              browseLan:
                  ({Duration timeout = const Duration(seconds: 3)}) async =>
                      const [],
              rediscoverStall: const Duration(seconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      store.subscribeSession(_sid);
      transport.pushAck(id: 's-$_sid');
      await Future<void>.delayed(Duration.zero);

      // After the ack, streaming tokens must fold in one-by-one (no buffering).
      transport.pushEvent(seq: 1, sessionId: _sid);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(storeControllerProvider).events[_sid]!.length, 1);
    });

    test(
      'send during replay waits for the real echo instead of reusing its seq',
      () async {
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
                browseLan:
                    ({Duration timeout = const Duration(seconds: 3)}) async =>
                        const [],
                rediscoverStall: const Duration(seconds: 30),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final store = container.read(storeControllerProvider.notifier);
        await Future<void>.delayed(Duration.zero);

        store.subscribeSession(_sid);
        transport.pushEvent(seq: 1, sessionId: _sid);
        await Future<void>.delayed(Duration.zero);

        store.appendOptimisticMessage(_sid, 'new message');
        store.sendMessage(_sid, 'new message');

        // The replay cursor is still zero, so an optimistic event would steal
        // seq 1 from the buffered historical event. The command must still be
        // sent, but no optimistic bubble is safe until replay finishes.
        expect(
          container.read(storeControllerProvider).events[_sid] ?? const [],
          isEmpty,
        );
        expect(
          transport.sent.where(
            (e) =>
                e.t == MsgType.cmd &&
                e.body['kind'] == 'send.message' &&
                e.body['text'] == 'new message',
          ),
          hasLength(1),
        );

        transport.pushAck(id: 's-$_sid');
        await Future<void>.delayed(Duration.zero);
        transport.pushEvent(
          seq: 2,
          sessionId: _sid,
          kind: 'user.message',
          text: 'new message',
        );
        await Future<void>.delayed(Duration.zero);

        final state = container.read(storeControllerProvider);
        expect(state.cursors[_sid], 2);
        expect(state.events[_sid], hasLength(2));
        final items = foldEvents(
          state.events[_sid]!,
        ).whereType<UserMessageItem>().toList();
        expect(items.map((item) => item.text), ['new message']);
      },
    );

    test(
      'first message on a pending draft is not doubled by startup events',
      () async {
        // A draft session promotes on its first message: the server creates the
        // worktree + agent, whose startup emits a `session.commands` event
        // BEFORE the `user.message` echo. That startup event consumes a seq, so
        // an optimistic bubble's guessed seq (cursor+1) no longer matches the
        // echo's seq and the reducer can't dedup them — the first message would
        // render twice.
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
                browseLan:
                    ({Duration timeout = const Duration(seconds: 3)}) async =>
                        const [],
                rediscoverStall: const Duration(seconds: 30),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final store = container.read(storeControllerProvider.notifier);
        await Future<void>.delayed(Duration.zero);

        // The session shows up as a pending draft (no worktree/agent yet).
        transport.pushSessions([
          {'id': _sid, 'projectId': 'p1', 'agent': 'pi', 'pending': true},
        ]);
        store.subscribeSession(_sid);
        // A draft has no history, so its sub replay is an immediate empty ack.
        transport.pushAck(id: 's-$_sid');
        await Future<void>.delayed(Duration.zero);

        store.appendOptimisticMessage(_sid, 'first task');
        store.sendMessage(_sid, 'first task');

        // Promotion starts the agent: its startup `session.commands` (seq 1)
        // lands before the `user.message` echo (seq 2).
        transport.pushEvent(seq: 1, sessionId: _sid, kind: 'session.commands');
        transport.pushEvent(
          seq: 2,
          sessionId: _sid,
          kind: 'user.message',
          text: 'first task',
        );
        await Future<void>.delayed(Duration.zero);

        final state = container.read(storeControllerProvider);
        final items = foldEvents(
          state.events[_sid]!,
        ).whereType<UserMessageItem>().toList();
        expect(items.map((item) => item.text), ['first task']);
      },
    );
  });

  group('StoreController — repo refresh after project add', () {
    test('addProject requests repo.refresh after server ack', () async {
      final transport = _SnapshotTransport();
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
              browseLan:
                  ({Duration timeout = const Duration(seconds: 3)}) async =>
                      const [],
              rediscoverStall: const Duration(seconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      final addFuture = store.addProject('/repo/makit');
      await Future<void>.delayed(Duration.zero);
      await addFuture;

      expect(
        transport.sent.where(
          (e) => e.t == MsgType.cmd && e.body['kind'] == 'repo.refresh',
        ),
        isNotEmpty,
      );
    });

    test('refreshGithubBudget sends github.refresh', () async {
      final transport = _SnapshotTransport();
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
              browseLan:
                  ({Duration timeout = const Duration(seconds: 3)}) async =>
                      const [],
              rediscoverStall: const Duration(seconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      // The /rate_limit endpoint is quota-exempt (SPEC-32 §4), so this is the
      // one control in the popover that costs the user nothing to press.
      await store.refreshGithubBudget();

      expect(
        transport.sent.where(
          (e) => e.t == MsgType.cmd && e.body['kind'] == 'github.refresh',
        ),
        isNotEmpty,
      );
    });

    test('setGithubPollingPaused sends github.pause with the flag', () async {
      final transport = _SnapshotTransport();
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
              browseLan:
                  ({Duration timeout = const Duration(seconds: 3)}) async =>
                      const [],
              rediscoverStall: const Duration(seconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      await store.setGithubPollingPaused(true);

      final sent = transport.sent
          .where((e) => e.t == MsgType.cmd && e.body['kind'] == 'github.pause')
          .toList();
      expect(sent, isNotEmpty);
      expect(sent.first.body['paused'], isTrue);
    });

    test('addProject succeeds when server rejects repo.refresh', () async {
      // An older server that predates SPEC-11 replies to `repo.refresh` with
      // `err {unknown cmd}`. The project was still added (project.add acked and
      // the server broadcasts its own repos.snapshot), so the best-effort
      // refresh must not turn a successful add into a failure.
      final transport = _SnapshotTransport(errOnRepoRefresh: true);
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
              browseLan:
                  ({Duration timeout = const Duration(seconds: 3)}) async =>
                      const [],
              rediscoverStall: const Duration(seconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      final addFuture = store.addProject('/repo/makit');
      await Future<void>.delayed(Duration.zero);

      expect(await addFuture, 'p-new');
    });

    test('project mutations do not wait for a dropped repo.refresh', () async {
      final transport = _SnapshotTransport(dropRepoRefresh: true);
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
              browseLan:
                  ({Duration timeout = const Duration(seconds: 3)}) async =>
                      const [],
              rediscoverStall: const Duration(seconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        store
            .addProject('/repo/makit')
            .timeout(const Duration(milliseconds: 100)),
        completion('p-new'),
      );
      await expectLater(
        store.removeProject('p-new').timeout(const Duration(milliseconds: 100)),
        completes,
      );
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

  void pushEvent({
    required int seq,
    required String sessionId,
    String kind = 'agent.message',
    String? text,
  }) {
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
            'kind': kind,
            'payload': {'text': text ?? 'm$seq'},
          },
        },
      ),
    );
  }

  void pushAck({required String id}) {
    _frames.add(Envelope(t: MsgType.ack, id: id));
  }

  void pushSessions(List<Map<String, dynamic>> sessions) {
    _frames.add(
      Envelope(
        t: MsgType.event,
        id: 'snap',
        body: {'kind': 'sessions.snapshot', 'sessions': sessions},
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

/// Transport that auto-acks cmd requests and lets tests inject snapshot events.
class _SnapshotTransport implements Transport {
  _SnapshotTransport({
    this.errOnRepoRefresh = false,
    this.dropRepoRefresh = false,
  });

  /// When true, reply to `repo.refresh` with an `err` frame (mimicking a
  /// server that predates the command) instead of an `ack`.
  final bool errOnRepoRefresh;
  final bool dropRepoRefresh;

  final sent = <Envelope>[];
  final _frames = StreamController<Envelope>.broadcast();
  final _state = StreamController<WsState>.broadcast();

  void pushSnapshot(Envelope env) => _frames.add(env);

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
  void sendEnvelope(Envelope env) {
    sent.add(env);
    if (env.t == MsgType.cmd) {
      final kind = env.body['kind'];
      if (kind == 'repo.refresh' && dropRepoRefresh) return;
      if (kind == 'repo.refresh' && errOnRepoRefresh) {
        _frames.add(
          Envelope(
            t: MsgType.err,
            id: env.id,
            body: {
              'code': 'bad_request',
              'message': 'unknown cmd: repo.refresh',
            },
          ),
        );
        return;
      }
      final body = kind == 'project.add'
          ? {'projectId': 'p-new'}
          : <String, dynamic>{};
      _frames.add(Envelope(t: MsgType.ack, id: env.id, body: body));
    }
  }

  @override
  void forceReconnect() {}
}

class _FakeStorage implements SecureStore {
  _FakeStorage(this.data);
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
