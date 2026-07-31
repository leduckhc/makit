import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';

/// A representative full `budget` payload (the object under the `budget` key of
/// a `github.budget` frame). Buckets present, 60-slot history, non-null stats.
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
  group('GithubBudget.fromJson', () {
    test('parses a full budget, all three buckets + 60-slot history', () {
      final b = GithubBudget.fromJson(_fullBudget());

      expect(b.level, BudgetLevel.warm);
      expect(b.burnPerHour, 340);
      expect(b.msUntilEmpty, 1080000);
      expect(b.retryAfterMs, isNull);
      expect(b.measuredAt, 1785499400000);
      expect(b.throttles, ['unresolved counts on demand', 'poll 30s']);

      expect(b.core, isNotNull);
      expect(b.core!.limit, 5000);
      expect(b.core!.remaining, 1769);
      expect(b.core!.resetAt, 1785500000000);
      expect(b.core!.mine, 2100);
      expect(b.core!.others, 1131);

      expect(b.graphql!.remaining, 4188);
      expect(b.search!.limit, 30);
      expect(b.search!.remaining, 24);

      expect(b.history, hasLength(60));
      expect(b.history.first.mine, 0);
      expect(b.history.last.mine, 59);

      expect(b.stats, isNotNull);
      expect(b.stats!.execs, 412);
      expect(b.stats!.cacheHits, 1893);
    });

    test('empty buckets map ⇒ all three bucket fields null, no throw', () {
      final b = GithubBudget.fromJson({
        ..._fullBudget(),
        'buckets': <String, dynamic>{},
      });
      expect(b.core, isNull);
      expect(b.graphql, isNull);
      expect(b.search, isNull);
    });

    test('garbage bucket value ⇒ that bucket null, others intact', () {
      final j = _fullBudget();
      (j['buckets'] as Map)['core'] = 'nope';
      final b = GithubBudget.fromJson(j);
      expect(b.core, isNull);
      expect(b.graphql, isNotNull);
      expect(b.search, isNotNull);
    });

    test('null bucket value ⇒ that bucket null (unmeasured ≠ empty)', () {
      final j = _fullBudget();
      (j['buckets'] as Map)['graphql'] = null;
      final b = GithubBudget.fromJson(j);
      expect(b.graphql, isNull);
      expect(b.core, isNotNull);
    });

    test('null msUntilEmpty / retryAfterMs survive as null', () {
      final b = GithubBudget.fromJson({
        ..._fullBudget(),
        'msUntilEmpty': null,
        'retryAfterMs': null,
      });
      expect(b.msUntilEmpty, isNull);
      expect(b.retryAfterMs, isNull);
    });

    test('retryAfterMs present survives as an int', () {
      final b = GithubBudget.fromJson({..._fullBudget(), 'retryAfterMs': 5000});
      expect(b.retryAfterMs, 5000);
    });

    test('absent history ⇒ empty list', () {
      final j = _fullBudget()..remove('history');
      final b = GithubBudget.fromJson(j);
      expect(b.history, isEmpty);
    });

    test('absent stats ⇒ null (unmeasured, distinct from zero counters)', () {
      final j = _fullBudget()..remove('stats');
      final b = GithubBudget.fromJson(j);
      expect(b.stats, isNull);
    });

    test('unknown level string ⇒ BudgetLevel.unknown', () {
      final b = GithubBudget.fromJson({..._fullBudget(), 'level': 'wat'});
      expect(b.level, BudgetLevel.unknown);
    });

    test('absent level ⇒ BudgetLevel.unknown', () {
      final j = _fullBudget()..remove('level');
      expect(GithubBudget.fromJson(j).level, BudgetLevel.unknown);
    });

    test('bucket missing limit/remaining ⇒ null bucket', () {
      final j = _fullBudget();
      (j['buckets'] as Map)['core'] = {'mine': 1};
      expect(GithubBudget.fromJson(j).core, isNull);
    });
  });
}
