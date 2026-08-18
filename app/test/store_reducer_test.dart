import 'dart:async';
import 'dart:convert';

import 'package:makit/store/secure_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
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

  group('StoreController — github.watch survives a reconnect', () {
    /// A container wired to [transport], with the store booted and settled.
    Future<StoreController> boot(ProviderContainer container) async {
      final store = container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      return store;
    }

    ProviderContainer containerFor(_SnapshotTransport transport) {
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
      return container;
    }

    List<Envelope> watchCmds(_SnapshotTransport t) => t.sent
        .where((e) => e.t == MsgType.cmd && e.body['kind'] == 'github.watch')
        .toList();

    test('an open panel re-subscribes when the socket comes back', () async {
      // The server drops per-client watchers on disconnect (exactly like `sub`),
      // so without a replay an open panel silently falls back to the slow 60s
      // cadence and never recovers until the user closes and reopens it.
      final transport = _SnapshotTransport();
      final store = await boot(containerFor(transport));
      await store.watchGithubBudget(true);
      transport.sent.clear();

      transport.pushState(WsState.reconnecting);
      transport.pushState(WsState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(watchCmds(transport), hasLength(1));
      expect(watchCmds(transport).single.body['watching'], true);
    });

    test('a closed panel is not re-subscribed on reconnect', () async {
      final transport = _SnapshotTransport();
      final store = await boot(containerFor(transport));
      await store.watchGithubBudget(true);
      await store.watchGithubBudget(false);
      transport.sent.clear();

      transport.pushState(WsState.reconnecting);
      transport.pushState(WsState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(watchCmds(transport), isEmpty);
    });
  });

  group('StoreController — ports.watch survives a reconnect', () {
    ProviderContainer containerFor(_SnapshotTransport transport) {
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
      return container;
    }

    List<Envelope> portsCmds(_SnapshotTransport t) => t.sent
        .where((e) => e.t == MsgType.cmd && e.body['kind'] == 'ports.watch')
        .toList();

    test('a held ports watch re-arms when the socket comes back', () async {
      // A reconnect builds a fresh server-side client whose `watchingPorts`
      // defaults to false, while the app's ref-count is still > 0 (rows never
      // unmounted). Without a replay the glyphs freeze — no watcher, no scan.
      final transport = _SnapshotTransport();
      final container = containerFor(transport);
      container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      // Hold the watch (0→1), exactly as a mounted row does.
      container.read(portsWatchProvider).watch();
      await Future<void>.delayed(Duration.zero);
      transport.sent.clear();

      transport.pushState(WsState.reconnecting);
      transport.pushState(WsState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(portsCmds(transport), hasLength(1));
      expect(portsCmds(transport).single.body['on'], true);
    });

    test('a released ports watch does not re-arm on reconnect', () async {
      final transport = _SnapshotTransport();
      final container = containerFor(transport);
      container.read(storeControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      final watch = container.read(portsWatchProvider)..watch();
      watch.release();
      await Future<void>.delayed(Duration.zero);
      transport.sent.clear();

      transport.pushState(WsState.reconnecting);
      transport.pushState(WsState.connected);
      await Future<void>.delayed(Duration.zero);

      expect(portsCmds(transport), isEmpty);
    });
  });

  group('StoreController — sub carries fromSeq cursor', () {
    test('a first sub asks for the whole history, cursor or not', () async {
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

      // The server auto-mirrors every session's events to every authed client,
      // subscribed or not, and the reducer advances that session's cursor. If
      // the cursor were used as `fromSeq` here the server would replay nothing,
      // so the history before this client connected — including the session's
      // one-shot `session.meta` / `session.commands` at the very start of the
      // log — would never arrive.
      transport.pushEvent(seq: 7, sessionId: _sid);
      await Future<void>.delayed(Duration.zero);

      transport.sent.clear();
      store.subscribeSession(_sid);

      final sub = transport.sent.singleWhere((e) => e.t == MsgType.sub);
      expect(sub.body['sessionId'], _sid);
      expect(sub.body['fromSeq'], 0);
    });

    test('a resub after a full replay asks only for newer events', () async {
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

      // Full replay, closed by its ack → this client now holds the history
      // contiguously, so a reconnect only needs the gap.
      store.subscribeSession(_sid);
      transport.pushEvent(seq: 7, sessionId: _sid);
      transport.pushAck(id: 's-$_sid');
      await Future<void>.delayed(Duration.zero);

      transport.sent.clear();
      transport.pushState(WsState.reconnecting);
      transport.pushState(WsState.connected);
      await Future<void>.delayed(Duration.zero);

      final sub = transport.sent.singleWhere((e) => e.t == MsgType.sub);
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

    test(
      'a full replay rebuilds a session the auto-mirror had only tailed',
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

        // A session streaming in the background: its live events reach this
        // client (auto-mirror) long before the user opens it, so the store holds
        // its tail — and a cursor at the head.
        transport.pushEvent(seq: 9, sessionId: _sid, text: 'tail');
        await Future<void>.delayed(Duration.zero);

        store.subscribeSession(_sid);
        await Future<void>.delayed(Duration.zero);

        // The replay carries the whole log, including the one-shot sticky state
        // the agent emitted at spawn (seq 1/2) and the tail we already had.
        transport.pushEvent(
          seq: 1,
          sessionId: _sid,
          kind: 'session.meta',
          payload: {
            'thinking': '',
            'models': [
              {'provider': 'anthropic', 'id': 'sonnet', 'name': 'Sonnet'},
            ],
          },
        );
        transport.pushEvent(
          seq: 2,
          sessionId: _sid,
          kind: 'session.commands',
          payload: {
            'commands': [
              {'name': 'skill:foo', 'description': 'd', 'source': 'skill'},
            ],
          },
        );
        transport.pushEvent(seq: 3, sessionId: _sid, text: 'history');
        transport.pushEvent(seq: 9, sessionId: _sid, text: 'tail');
        transport.pushAck(id: 's-$_sid');
        await Future<void>.delayed(Duration.zero);

        // Sticky state landed: without it the composer has no model selector
        // and no slash commands.
        expect(container.read(sessionMetaProvider(_sid))?.models, hasLength(1));
        expect(container.read(commandsProvider(_sid)), hasLength(1));
        // History landed too, and the tail we already held is not duplicated.
        final texts = container
            .read(storeControllerProvider)
            .events[_sid]!
            .map((e) => e.payload['text'])
            .toList();
        expect(texts, ['history', 'tail']);
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

    test(
      'a mid-turn message gets no optimistic bubble, so no server event is swallowed (SPEC-35)',
      () async {
        // While the agent is running, the next seq belongs to the agent's own
        // stream, not to our echo: the message will be steered or queued and
        // echoed later (or never, if cancelled). An optimistic bubble at
        // cursor+1 would therefore advance the cursor past a REAL event and the
        // reducer would drop it.
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

        transport.pushSessions([
          {
            'id': _sid,
            'projectId': 'p1',
            'agent': 'codex',
            'status': 'running',
          },
        ]);
        store.subscribeSession(_sid);
        transport.pushAck(id: 's-$_sid');
        transport.pushEvent(
          seq: 1,
          sessionId: _sid,
          kind: 'user.message',
          text: 'long task',
        );
        await Future<void>.delayed(Duration.zero);

        store.appendOptimisticMessage(_sid, 'mid-turn');
        store.sendMessage(_sid, 'mid-turn');

        // The agent keeps streaming: seq 2 is ITS event, not our echo.
        transport.pushEvent(seq: 2, sessionId: _sid, text: 'still working');
        await Future<void>.delayed(Duration.zero);

        final state = container.read(storeControllerProvider);
        final items = foldEvents(state.events[_sid]!);
        expect(items.whereType<AgentMessageItem>().map((i) => i.text), [
          'still working',
        ], reason: 'the agent event must not be swallowed by a guessed seq');
        expect(
          items.whereType<UserMessageItem>().map((i) => i.text),
          ['long task'],
          reason: 'the mid-turn message shows as a queue chip until delivered',
        );
      },
    );
  });

  group('StoreController — optimistic bubbles vs the queue', () {
    test('an IDLE session with a queue gets no optimistic bubble', () async {
      // The server enqueues whenever a queue exists or a flush is in flight,
      // whatever the status — so a bubble here would claim the message was sent
      // AND eat the seq the next real event needs.
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

      transport.pushSessions([
        {
          'id': _sid,
          'projectId': 'p1',
          'agent': 'pi',
          // Idle, but with one message still waiting to be delivered.
          'status': 'idle',
          'queued': [
            {'id': 'q1', 'text': 'waiting', 'queuedAt': 1},
          ],
        },
      ]);
      store.subscribeSession(_sid);
      transport.pushAck(id: 's-$_sid');
      await Future<void>.delayed(Duration.zero);

      store.appendOptimisticMessage(_sid, 'and another');
      await Future<void>.delayed(Duration.zero);

      final events = container.read(storeControllerProvider).events[_sid];
      expect(
        events?.where((e) => e.kind == EventKind.userMessage) ?? const [],
        isEmpty,
        reason: 'the queue is the feedback here, not a chat bubble',
      );
    });
  });

  group('StoreController — queue commands (SPEC-35/36/37)', () {
    /// Every queue command carries the MESSAGE id as `queuedId`.
    ///
    /// Regression: [Envelope.toJson] spreads the command body over the frame, so
    /// a body field named `id` silently replaced the request id — the ack came
    /// back labelled with the queued message and could never be matched to the
    /// command that caused it.
    test(
      'carry the message id as queuedId, leaving the request id intact',
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

        store.cancelQueuedMessage(_sid, 'q1');
        store.updateQueuedMessage(_sid, 'q2', 'edited');
        store.promoteQueuedMessage(_sid, 'q3');
        store.reorderQueuedMessages(_sid, ['q3', 'q2']);
        await Future<void>.delayed(Duration.zero);

        final cmds = transport.sent
            .where((e) => e.t == MsgType.cmd)
            .where((e) => (e.body['kind'] as String).startsWith('queue.'))
            .toList();
        expect(cmds.map((e) => e.body['kind']), [
          'queue.cancel',
          'queue.update',
          'queue.promote',
          'queue.reorder',
        ]);

        for (final cmd in cmds) {
          // What actually goes on the wire — `toJson`, not `body`, is where the
          // shadowing happened.
          final wire = cmd.toJson();
          expect(
            wire['id'],
            cmd.id,
            reason: '${cmd.body['kind']} must not overwrite the request id',
          );
          expect(wire['id'], isNot(anyOf('q1', 'q2', 'q3')));
        }
        expect(cmds[0].toJson()['queuedId'], 'q1');
        expect(cmds[1].toJson()['queuedId'], 'q2');
        expect(cmds[1].toJson()['text'], 'edited');
        expect(cmds[2].toJson()['queuedId'], 'q3');
        expect(cmds[3].toJson()['ids'], ['q3', 'q2']);
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
            'sessionId': sessionId,
            'ts': seq * 1000,
            'kind': kind,
            'payload': payload ?? {'text': text ?? 'm$seq'},
          },
        },
      ),
    );
  }

  void pushAck({required String id}) {
    _frames.add(Envelope(t: MsgType.ack, id: id));
  }

  /// Drive the state stream, so a test can stage a drop + reconnect.
  void pushState(WsState s) => _state.add(s);

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

  /// Drive the state stream, so a test can stage a drop + reconnect.
  void pushState(WsState s) => _state.add(s);

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
