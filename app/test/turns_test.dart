import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/turns.dart';
import 'package:makit/transport/protocol.dart';

/// Event at [seq] with `ts = seq * 1000` so a span's wall clock reads directly
/// off the seqs (SPEC-session-timings D18 table test).
SessionEvent _ev(int seq, EventKind k, [Map<String, dynamic> p = const {}]) =>
    SessionEvent(
      seq: seq,
      sessionId: 's1',
      ts: seq * 1000,
      kind: k,
      payload: p,
    );

SessionEvent _status(int seq, String status) =>
    _ev(seq, EventKind.sessionStatus, {'status': status});

SessionEvent _user(int seq, {bool steered = false}) =>
    _ev(seq, EventKind.userMessage, {'text': 'hi', 'steered': steered});

SessionEvent _tool(int seq) =>
    _ev(seq, EventKind.toolCallStart, {'callId': 'c$seq', 'name': 'bash'});

SessionEvent _agent(int seq) =>
    _ev(seq, EventKind.agentMessage, {'text': 'done'});

void main() {
  group('deriveTurns', () {
    test('an ordinary turn: user → running → tool → agent → idle', () {
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _tool(3),
        _agent(4),
        _status(5, 'idle'),
      ]);
      expect(turns.length, 1);
      final t = turns.single;
      expect(t.openTs, 1000);
      expect(t.closeTs, 5000);
      expect(t.wallMs, 4000);
      expect(t.gatedMs, 0);
      expect(t.toolCount, 1);
      expect(t.hasAgentMessage, isTrue);
      expect(t.openSeq, 1);
      expect(t.closeSeq, 5);
    });

    test('a steered user message does not open a turn', () {
      // The steer is injected into the already-running turn; only the first
      // (non-steered) opener counts, so this is exactly one turn.
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _tool(3),
        _user(4, steered: true),
        _agent(5),
        _status(6, 'idle'),
      ]);
      expect(turns.length, 1);
      expect(turns.single.openTs, 1000);
      expect(turns.single.toolCount, 1);
    });

    test('a gate accumulates into gatedMs, not a second turn', () {
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _tool(3),
        _status(4, 'awaiting-approval'),
        _status(7, 'running'), // 3s gated (4000 → 7000)
        _agent(8),
        _status(9, 'idle'),
      ]);
      expect(turns.length, 1);
      final t = turns.single;
      expect(t.wallMs, 8000);
      expect(t.gatedMs, 3000);
      expect(t.agentMs, 5000);
    });

    test('a repeated gate status keeps the first gate entry', () {
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _tool(3),
        _status(4, 'awaiting-approval'),
        _status(5, 'awaiting-approval'),
        _status(7, 'running'), // still 3s gated (4000 → 7000)
        _agent(8),
        _status(9, 'idle'),
      ]);
      expect(turns.single.gatedMs, 3000);
    });

    test('a gate that closes directly on idle is still gated time', () {
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _tool(3),
        _status(4, 'awaiting-approval'),
        _status(9, 'idle'), // 5s gated (4000 → 9000)
      ]);
      expect(turns.length, 1);
      final t = turns.single;
      expect(t.wallMs, 8000);
      expect(t.gatedMs, 5000);
      expect(t.agentMs, 3000);
    });

    test('awaiting-input also gates and never closes the turn', () {
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _status(3, 'awaiting-input'),
        _status(8, 'running'), // 5s gated
        _agent(9),
        _status(10, 'idle'),
      ]);
      expect(turns.single.gatedMs, 5000);
    });

    test('a leading bare idle closes nothing', () {
      final turns = deriveTurns([
        _status(1, 'idle'),
        _user(2),
        _status(3, 'running'),
        _agent(4),
        _status(5, 'idle'),
      ]);
      expect(turns.length, 1);
      expect(turns.single.openTs, 2000);
    });

    test(
      'running opens a turn when no user message precedes it (partial replay)',
      () {
        final turns = deriveTurns([
          _status(2, 'running'),
          _tool(3),
          _status(5, 'idle'),
        ]);
        expect(turns.length, 1);
        expect(turns.single.openTs, 2000);
        expect(turns.single.toolCount, 1);
      },
    );

    test('nested running pairs close on a single idle', () {
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _status(3, 'running'), // repeated; harmless
        _tool(4),
        _status(6, 'idle'),
      ]);
      expect(turns.length, 1);
      expect(turns.single.closeTs, 6000);
    });

    test('a late exited does NOT close the turn (no three-day span)', () {
      // manager.ts records exited on a failed reattach, days later.
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _tool(3),
        _ev(4, EventKind.sessionStatus, {'status': 'exited'}),
      ]);
      expect(turns, isEmpty, reason: 'unclosed → no span');
    });

    test('an unclosed (live) turn yields no span', () {
      final turns = deriveTurns([_user(1), _status(2, 'running'), _tool(3)]);
      expect(turns, isEmpty);
    });

    test(
      'a turn/start failure bracket (no tool, no message) yields no receipt',
      () {
        // codex: user.message → running → session.error → idle, milliseconds wide.
        final turns = deriveTurns([
          _user(1),
          _status(2, 'running'),
          _ev(3, EventKind.sessionError, {'message': 'boom'}),
          _status(4, 'idle'),
        ]);
        expect(turns, isEmpty, reason: 'D10a: no tool + no agent message');
      },
    );

    test('a fast turn that produced an agent message IS receipted', () {
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _agent(3),
        _status(4, 'idle'),
      ]);
      expect(turns.length, 1);
      expect(turns.single.hasAgentMessage, isTrue);
    });

    test('an unrepresentable span (close before open) is dropped (D10b)', () {
      final turns = deriveTurns([
        SessionEvent(
          seq: 1,
          sessionId: 's1',
          ts: 9000,
          kind: EventKind.userMessage,
          payload: const {'text': 'hi'},
        ),
        SessionEvent(
          seq: 2,
          sessionId: 's1',
          ts: 9000,
          kind: EventKind.sessionStatus,
          payload: const {'status': 'running'},
        ),
        _tool(3),
        SessionEvent(
          seq: 4,
          sessionId: 's1',
          ts: 5000, // clock stepped backwards
          kind: EventKind.sessionStatus,
          payload: const {'status': 'idle'},
        ),
      ]);
      expect(turns, isEmpty);
    });

    test('two turns are derived independently', () {
      final turns = deriveTurns([
        _user(1),
        _status(2, 'running'),
        _agent(3),
        _status(4, 'idle'),
        _user(5),
        _status(6, 'running'),
        _tool(7),
        _agent(8),
        _status(9, 'idle'),
      ]);
      expect(turns.length, 2);
      expect(turns[0].openSeq, 1);
      expect(turns[1].openSeq, 5);
      expect(turns[1].toolCount, 1);
    });
  });

  group('turnRollup (D11 arithmetic)', () {
    TurnSpan span({required int wall, int gated = 0}) => TurnSpan(
      openTs: 0,
      closeTs: wall,
      openSeq: 0,
      closeSeq: 1,
      gatedMs: gated,
      toolCount: 1,
      hasAgentMessage: true,
    );

    test('empty spans → zero turns, no median', () {
      final r = turnRollup(const []);
      expect(r.turnCount, 0);
      expect(r.agentMs, 0);
      expect(r.medianWallMs, isNull);
    });

    test('agent time is the sum of (wall − gated)', () {
      final r = turnRollup([span(wall: 10000, gated: 3000), span(wall: 5000)]);
      expect(r.turnCount, 2);
      expect(r.agentMs, 12000);
    });

    test('median of an odd count is the middle wall clock', () {
      final r = turnRollup([
        span(wall: 1000),
        span(wall: 9000),
        span(wall: 3000),
      ]);
      expect(r.medianWallMs, 3000);
    });

    test('median of an even count averages the two middle values', () {
      final r = turnRollup([
        span(wall: 1000),
        span(wall: 2000),
        span(wall: 3000),
        span(wall: 6000),
      ]);
      expect(r.medianWallMs, 2500);
    });

    test('median is not the mean — an outlier does not skew it', () {
      final r = turnRollup([
        span(wall: 1000),
        span(wall: 2000),
        span(wall: 2400000), // a 40-minute gh pr checks --watch
      ]);
      expect(r.medianWallMs, 2000);
    });
  });

  group('openTurnStartMs (D8)', () {
    test('returns the opener of an unclosed turn', () {
      final ts = openTurnStartMs([_user(1), _status(2, 'running'), _tool(3)]);
      expect(ts, 1000);
    });

    test('is null once the turn closed on idle', () {
      final ts = openTurnStartMs([
        _user(1),
        _status(2, 'running'),
        _status(3, 'idle'),
      ]);
      expect(ts, isNull);
    });

    test('a steered message does not reopen a closed turn', () {
      final ts = openTurnStartMs([
        _user(1),
        _status(2, 'running'),
        _status(3, 'idle'),
        _user(4, steered: true),
      ]);
      expect(ts, isNull);
    });
  });
}
