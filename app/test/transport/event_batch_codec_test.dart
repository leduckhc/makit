// The app must understand one frame that carries many events.
//
// The server sent one `session.event` frame per streamed token — a peak of 2184
// frames per second, each one a decode here and a radio wake on a phone. It now
// collects them into a `session.events` frame for a client that says it can read
// one, which the app announces with `batch: true` in `hello`.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/transport/protocol.dart';

Map<String, dynamic> _event(int seq, {String sessionId = 's1'}) => {
  'seq': seq,
  'sessionId': sessionId,
  'ts': 1700000000000 + seq,
  'kind': 'agent.message.delta',
  'payload': {'msgId': 'm1', 'chunk': 'c$seq'},
};

void main() {
  test('a batch frame decodes to its events, in order', () {
    final decoded = WireCodec.decode(
      Envelope(
        t: MsgType.event,
        id: 'evs-1',
        body: {
          'kind': 'session.events',
          'events': [_event(1), _event(2), _event(3)],
        },
      ),
    );

    expect(decoded, isA<SessionEventsFrame>());
    expect((decoded! as SessionEventsFrame).events.map((e) => e.seq), [
      1,
      2,
      3,
    ]);
  });

  test('a batch with one unreadable event keeps the readable ones', () {
    final decoded = WireCodec.decode(
      Envelope(
        t: MsgType.event,
        id: 'evs-2',
        body: {
          'kind': 'session.events',
          'events': [_event(1), 'not an event', _event(2)],
        },
      ),
    );

    expect((decoded! as SessionEventsFrame).events.map((e) => e.seq), [1, 2]);
  });

  test('an empty batch decodes to nothing at all', () {
    final decoded = WireCodec.decode(
      Envelope(
        t: MsgType.event,
        id: 'evs-3',
        body: {'kind': 'session.events', 'events': <Object>[]},
      ),
    );
    expect(decoded, isNull);
  });

  test('a batch reduces exactly like the same events one at a time', () {
    final events = [
      SessionEvent(
        seq: 1,
        sessionId: 's1',
        ts: 1,
        kind: EventKind.userMessage,
        payload: const {'text': 'go'},
      ),
      SessionEvent(
        seq: 2,
        sessionId: 's1',
        ts: 2,
        kind: EventKind.agentMessageDelta,
        payload: const {'msgId': 'm1', 'chunk': 'hi'},
      ),
      SessionEvent(
        seq: 3,
        sessionId: 's1',
        ts: 3,
        kind: EventKind.agentMessage,
        payload: const {'msgId': 'm1', 'text': 'hi'},
      ),
    ];

    var oneAtATime = StoreState.empty();
    for (final e in events) {
      oneAtATime = reduceEvent(oneAtATime, e);
    }
    final batched = reduce(StoreState.empty(), SessionEventsFrame(events));

    expect(batched.cursors, oneAtATime.cursors);
    expect(
      batched.transcripts['s1']!.rows.length,
      oneAtATime.transcripts['s1']!.rows.length,
    );
    expect(batched.events['s1']!.length, oneAtATime.events['s1']!.length);
  });
}
