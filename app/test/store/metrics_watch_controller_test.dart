import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/metrics.dart';

void main() {
  group('MetricsWatchController ref-counting', () {
    test('two watch() send exactly one {on:true}', () {
      final sent = <bool>[];
      final c = MetricsWatchController(sent.add);
      c.watch();
      c.watch();
      expect(sent, [true]);
      expect(c.watcherCount, 2);
    });

    test('releasing one of two watchers sends nothing', () {
      final sent = <bool>[];
      final c = MetricsWatchController(sent.add)
        ..watch()
        ..watch();
      sent.clear();
      c.release();
      expect(sent, isEmpty);
      expect(c.watcherCount, 1);
    });

    test('releasing the last watcher sends {on:false}', () {
      final sent = <bool>[];
      final c = MetricsWatchController(sent.add)
        ..watch()
        ..watch();
      sent.clear();
      c.release();
      c.release();
      expect(sent, [false]);
      expect(c.watcherCount, 0);
    });

    test('release with no watchers never sends a spurious off', () {
      final sent = <bool>[];
      MetricsWatchController(sent.add).release();
      expect(sent, isEmpty);
    });
  });
}
