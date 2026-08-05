import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/metrics.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/codec.dart';

MetricsSample _sample(int ts) => MetricsSample.fromJson({
  'ts': ts,
  'server': {
    'pid': 1,
    'rssBytes': 1,
    'cpuPercent': 0.5,
    'cpuSeconds': 1,
    'eventLoop': {'p50': 1, 'p99': 2},
  },
})!;

void main() {
  group('reduce metrics.sample', () {
    test('a lone sample appends to the ring', () {
      var state = StoreState.empty();
      state = reduce(state, MetricsSampleFrame(_sample(1), null));
      state = reduce(state, MetricsSampleFrame(_sample(2), null));
      expect(state.metrics.map((s) => s.ts), [1, 2]);
    });

    test('a frame with history replaces the ring, then samples append', () {
      var state = StoreState.empty();
      state = reduce(state, MetricsSampleFrame(_sample(9), null));
      // Backfill frame: history + the current sample replaces the ring.
      state = reduce(
        state,
        MetricsSampleFrame(_sample(3), [_sample(1), _sample(2)]),
      );
      expect(state.metrics.map((s) => s.ts), [1, 2, 3]);
      state = reduce(state, MetricsSampleFrame(_sample(4), null));
      expect(state.metrics.map((s) => s.ts), [1, 2, 3, 4]);
    });

    test('the 1800 cap drops oldest', () {
      var state = StoreState.empty();
      for (var i = 0; i < 1805; i++) {
        state = reduce(state, MetricsSampleFrame(_sample(i), null));
      }
      expect(state.metrics, hasLength(1800));
      expect(state.metrics.first.ts, 5);
      expect(state.metrics.last.ts, 1804);
    });
  });
}
