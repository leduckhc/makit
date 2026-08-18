import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/transport/protocol.dart';

/// SPEC-context-usage — context usage: the model, the reducer, and the one rule that
/// matters throughout: **absent is not zero**. A field the agent never reported
/// must stay null so the UI can render "unknown" rather than a 0%/full bar.

SessionEvent _usage(String sid, int seq, Map<String, dynamic> payload) =>
    SessionEvent(
      seq: seq,
      sessionId: sid,
      ts: seq * 1000,
      kind: EventKind.sessionUsage,
      payload: payload,
    );

StoreState _seeded(List<String> sessionIds) => StoreState.empty().copyWith(
  sessions: [
    for (final id in sessionIds)
      Session(
        id: id,
        projectId: 'p1',
        agent: 'pi',
        title: 't',
        status: SessionStatus.idle,
        policy: ApprovalPolicy.askOnRisky,
      ),
  ],
);

void main() {
  group('SessionUsage.fromJson', () {
    test('reads the full codex-shaped payload', () {
      final u = SessionUsage.fromJson({
        'contextTokens': 19508,
        'contextWindow': 258400,
        'totals': {
          'total': 39000,
          'input': 38990,
          'cachedInput': 19200,
          'cacheWrite': 0,
          'output': 10,
          'reasoning': 0,
        },
        'cost': {'amount': 0.42, 'currency': 'USD'},
        'measuredAt': 1785497471188,
      });

      expect(u.contextTokens, 19508);
      expect(u.contextWindow, 258400);
      expect(u.totals?.total, 39000);
      expect(u.totals?.cachedInput, 19200);
      expect(u.cost?.amount, 0.42);
      expect(u.cost?.currency, 'USD');
      expect(u.measuredAt, 1785497471188);
    });

    test('leaves missing fields null instead of zeroing them', () {
      // ACP reports used/size only; codex reports no cost. A 0 here would draw
      // a real bar for a reading that was never taken.
      final u = SessionUsage.fromJson({'contextTokens': 100, 'measuredAt': 1});
      expect(u.contextTokens, 100);
      expect(u.contextWindow, isNull);
      expect(u.totals, isNull);
      expect(u.cost, isNull);
    });

    test('drops non-numeric junk rather than throwing', () {
      final u = SessionUsage.fromJson({
        'contextTokens': 'lots',
        'contextWindow': null,
        'cost': {'amount': 'free', 'currency': 'USD'},
        'measuredAt': 'now',
      });
      expect(u.contextTokens, isNull);
      expect(u.contextWindow, isNull);
      expect(u.cost, isNull);
      expect(u.measuredAt, 0);
    });

    test('needs both an amount and a currency to report a cost', () {
      expect(
        SessionUsage.fromJson({
          'cost': {'amount': 1.0},
        }).cost,
        isNull,
      );
      expect(
        SessionUsage.fromJson({
          'cost': {'currency': 'USD'},
        }).cost,
        isNull,
      );
    });
  });

  group('SessionUsage.fraction', () {
    test('is the ratio of context tokens to the window', () {
      const u = SessionUsage(
        contextTokens: 19508,
        contextWindow: 258400,
        measuredAt: 1,
      );
      expect(u.fraction, closeTo(0.0755, 0.0001));
    });

    test('is null when either half of the ratio is unmeasured', () {
      expect(
        const SessionUsage(contextTokens: 100, measuredAt: 1).fraction,
        isNull,
      );
      expect(
        const SessionUsage(contextWindow: 100, measuredAt: 1).fraction,
        isNull,
      );
    });

    test('is null on a zero window rather than dividing by zero', () {
      expect(
        const SessionUsage(
          contextTokens: 100,
          contextWindow: 0,
          measuredAt: 1,
        ).fraction,
        isNull,
      );
    });

    test('clamps a context that overshoots its window to 1.0', () {
      // Providers occasionally report a context slightly past the advertised
      // window; a >1 fraction would overflow the bar.
      expect(
        const SessionUsage(
          contextTokens: 300000,
          contextWindow: 258400,
          measuredAt: 1,
        ).fraction,
        1.0,
      );
    });
  });

  group('reduce — session.usage', () {
    test('stores the snapshot under its own session', () {
      final s = reduce(
        _seeded(['s1']),
        SessionEventFrame(
          _usage('s1', 1, {
            'contextTokens': 100,
            'contextWindow': 1000,
            'measuredAt': 5,
          }),
        ),
      );
      expect(s.usage['s1']?.contextTokens, 100);
      expect(s.usage['s2'], isNull);
    });

    test('is latest-wins: a newer snapshot replaces the old one wholly', () {
      // Every snapshot carries the complete picture, so the new one must not be
      // merged into the old — a field the agent stopped reporting must go away.
      var s = reduce(
        _seeded(['s1']),
        SessionEventFrame(
          _usage('s1', 1, {
            'contextTokens': 100,
            'contextWindow': 1000,
            'cost': {'amount': 0.1, 'currency': 'USD'},
            'measuredAt': 5,
          }),
        ),
      );
      s = reduce(
        s,
        SessionEventFrame(
          _usage('s1', 2, {
            'contextTokens': 200,
            'contextWindow': 1000,
            'measuredAt': 6,
          }),
        ),
      );
      expect(s.usage['s1']?.contextTokens, 200);
      expect(s.usage['s1']?.cost, isNull, reason: 'replaced, not merged');
    });

    test('keeps sessions independent', () {
      var s = reduce(
        _seeded(['s1', 's2']),
        SessionEventFrame(
          _usage('s1', 1, {'contextTokens': 100, 'measuredAt': 1}),
        ),
      );
      s = reduce(
        s,
        SessionEventFrame(
          _usage('s2', 1, {'contextTokens': 900, 'measuredAt': 1}),
        ),
      );
      expect(s.usage['s1']?.contextTokens, 100);
      expect(s.usage['s2']?.contextTokens, 900);
    });

    test('adds no chat item — usage is chrome, not transcript', () {
      final s = reduce(
        _seeded(['s1']),
        SessionEventFrame(
          _usage('s1', 1, {'contextTokens': 100, 'measuredAt': 1}),
        ),
      );
      expect(s.events['s1'] ?? const [], isEmpty);
    });
  });

  group('EventKind wire mapping', () {
    test('session.usage round-trips', () {
      expect(EventKind.sessionUsage.wire, 'session.usage');
      expect(EventKind.fromWire('session.usage'), EventKind.sessionUsage);
    });
  });
}
