import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/transport/protocol.dart';

Envelope _budgetEnv(Map<String, dynamic> budget) => Envelope(
  t: MsgType.event,
  id: 'x',
  body: {'kind': 'github.budget', 'budget': budget},
);

Map<String, dynamic> _fullBudget() => {
  'buckets': <String, dynamic>{
    'core': {
      'limit': 5000,
      'remaining': 1769,
      'resetAt': 1785500000000,
      'mine': 2100,
      'others': 1131,
    },
    'graphql': {
      'limit': 5000,
      'remaining': 4188,
      'resetAt': 1785500000000,
      'mine': 300,
      'others': 512,
    },
    'search': {
      'limit': 30,
      'remaining': 24,
      'resetAt': 1785499999000,
      'mine': 0,
      'others': 6,
    },
  },
  'burnPerHour': 340,
  'msUntilEmpty': 1080000,
  'level': 'warm',
  'throttles': ['unresolved counts on demand', 'poll 30s'],
  'retryAfterMs': null,
  'measuredAt': 1785499400000,
  'history': [
    for (var i = 0; i < 60; i++) {'mine': i, 'others': i % 3},
  ],
  'stats': {'execs': 412, 'cacheHits': 1893},
};

void main() {
  group('WireCodec — github.budget', () {
    test('decodes a full budget frame incl. all buckets + 60-slot history', () {
      final decoded = WireCodec.decode(_budgetEnv(_fullBudget()));
      expect(decoded, isA<GithubBudgetFrame>());
      final b = (decoded as GithubBudgetFrame).budget;
      expect(b.level, BudgetLevel.warm);
      expect(b.core!.remaining, 1769);
      expect(b.graphql!.remaining, 4188);
      expect(b.search!.limit, 30);
      expect(b.history, hasLength(60));
    });

    test('empty buckets ⇒ all bucket fields null, no throw', () {
      final decoded =
          WireCodec.decode(
                _budgetEnv({..._fullBudget(), 'buckets': <String, dynamic>{}}),
              )
              as GithubBudgetFrame;
      expect(decoded.budget.core, isNull);
      expect(decoded.budget.graphql, isNull);
      expect(decoded.budget.search, isNull);
    });

    test('garbage bucket value ⇒ that bucket null, others intact', () {
      final j = _fullBudget();
      (j['buckets'] as Map)['core'] = 'nope';
      final b = (WireCodec.decode(_budgetEnv(j)) as GithubBudgetFrame).budget;
      expect(b.core, isNull);
      expect(b.graphql, isNotNull);
      expect(b.search, isNotNull);
    });

    test('null msUntilEmpty / retryAfterMs survive as null', () {
      final b =
          (WireCodec.decode(
                    _budgetEnv({
                      ..._fullBudget(),
                      'msUntilEmpty': null,
                      'retryAfterMs': null,
                    }),
                  )
                  as GithubBudgetFrame)
              .budget;
      expect(b.msUntilEmpty, isNull);
      expect(b.retryAfterMs, isNull);
    });

    test('absent history ⇒ empty list', () {
      final j = _fullBudget()..remove('history');
      final b = (WireCodec.decode(_budgetEnv(j)) as GithubBudgetFrame).budget;
      expect(b.history, isEmpty);
    });

    test('budget frame with a non-map budget payload returns null', () {
      final env = Envelope(
        t: MsgType.event,
        id: 'x',
        body: {'kind': 'github.budget', 'budget': 'nope'},
      );
      expect(WireCodec.decode(env), isNull);
    });

    test('an unrelated kind is still ignored (no switch regression)', () {
      final env = Envelope(
        t: MsgType.event,
        id: 'x',
        body: {'kind': 'totally.unknown'},
      );
      expect(WireCodec.decode(env), isNull);
    });
  });

  test('a history containing malformed entries decodes to a filtered list', () {
    // The sparkline CustomPainter consumes this list directly, so a non-map or
    // fieldless entry must be dropped rather than reaching paint() or throwing.
    final decoded = WireCodec.decode(
      _budgetEnv({
        'buckets': const <String, dynamic>{},
        'level': 'healthy',
        'history': [
          {'mine': 2, 'others': 1},
          'bad',
          42,
          const <String, dynamic>{},
          {'mine': 'nope', 'others': 'nope'},
          {'mine': 5, 'others': 0},
        ],
      }),
    );
    expect(decoded, isA<GithubBudgetFrame>());
    final history = (decoded! as GithubBudgetFrame).budget.history;
    expect(history.length, 2, reason: 'only the two well-formed slots survive');
    expect(history.first.mine, 2);
    expect(history.last.mine, 5);
  });

  test('a non-list throttles or history value does not drop the frame', () {
    // `as List?` throws on a present non-null non-list, which would take down the
    // whole budget frame -- and, since decode failures are swallowed, silently
    // leave the footer stale. The contract for this file is tolerant decoding, so
    // a malformed collection must degrade to empty, not to nothing.
    final decoded = WireCodec.decode(
      _budgetEnv({
        'buckets': const <String, dynamic>{},
        'level': 'warm',
        'throttles': 'poll 30s',
        'history': 42,
      }),
    );
    expect(decoded, isA<GithubBudgetFrame>());
    final b = (decoded! as GithubBudgetFrame).budget;
    expect(b.throttles, isEmpty);
    expect(b.history, isEmpty);
    expect(b.level, BudgetLevel.warm, reason: 'the rest of the frame survives');
  });
}
