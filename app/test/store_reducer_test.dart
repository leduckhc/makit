import 'package:flutter_test/flutter_test.dart';
import 'package:pino/store/models.dart';
import 'package:pino/store/store.dart';
import 'package:pino/transport/codec.dart';
import 'package:pino/transport/protocol.dart';

const _sid = 's1';

SessionEvent _ev(int seq, EventKind kind, Map<String, dynamic> payload) =>
    SessionEvent(seq: seq, sessionId: _sid, ts: seq * 1000, kind: kind, payload: payload);

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
    test('optimistic user bubble (seq N) + server echo (seq N) → ONE bubble', () {
      var state = _seeded();
      // Optimistic append: takes seq = cursor + 1 = 1.
      state = reduceEvent(state, _ev(1, EventKind.userMessage, {'text': 'hi'}));
      // Server echoes the same message with the SAME seq.
      state = reduce(
        state,
        SessionEventFrame(_ev(1, EventKind.userMessage, {'text': 'hi'})),
      );

      final items = foldEvents(state.events[_sid]!)
          .whereType<UserMessageItem>()
          .toList();
      expect(items.length, 1);
      expect(items.single.text, 'hi');
      expect(state.cursors[_sid], 1);
    });

    test('duplicate and older seqs are dropped', () {
      var state = _seeded();
      state = reduceEvent(state, _ev(1, EventKind.userMessage, {'text': 'a'}));
      state = reduceEvent(state, _ev(2, EventKind.agentMessage, {'text': 'b'}));
      // Duplicate (seq 2) and older (seq 1) must be dropped.
      state = reduceEvent(state, _ev(2, EventKind.agentMessage, {'text': 'dup'}));
      state = reduceEvent(state, _ev(1, EventKind.userMessage, {'text': 'old'}));

      expect(state.events[_sid]!.length, 2);
      expect(state.cursors[_sid], 2);
    });

    test('session.commands advances cursor but adds no chat item', () {
      var state = _seeded();
      state = reduce(
        state,
        SessionEventFrame(_ev(1, EventKind.sessionCommands, {
          'commands': [
            {'name': 'fix', 'description': 'd', 'source': 'prompt'},
          ],
        })),
      );

      expect(state.cursors[_sid], 1);
      expect(state.events[_sid] ?? const [], isEmpty);
      expect(state.commands[_sid]!.length, 1);
      expect(state.commands[_sid]!.single.name, 'fix');
    });

    test('session.status + message preview bubble up to the session', () {
      var state = _seeded();
      state = reduce(
        state,
        SessionEventFrame(_ev(1, EventKind.sessionStatus, {'status': 'running'})),
      );
      var session = state.sessions.single;
      expect(session.status, SessionStatus.running);
      // status events are not chat items.
      expect(foldEvents(state.events[_sid] ?? const []), isEmpty);

      state = reduce(
        state,
        SessionEventFrame(_ev(2, EventKind.agentMessage, {'text': 'working on it'})),
      );
      session = state.sessions.single;
      expect(session.lastPreview, 'working on it');
      expect(session.lastActivityAt, 2000);
    });
  });
}
