import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/elapsed.dart';

void main() {
  group('formatElapsed — the ladder (SPEC-47 D13/D14)', () {
    test('one decimal only in the 2–10s band, trailing .0 stripped', () {
      expect(formatElapsed(2400), '2.4s');
      expect(formatElapsed(9100), '9.1s');
      expect(formatElapsed(2000), '2s');
    });

    test('whole seconds from 10s, rounded not truncated', () {
      expect(formatElapsed(12600), '13s');
      expect(formatElapsed(48000), '48s');
      expect(formatElapsed(59400), '59s');
    });

    test('minutes carry seconds, zero-padded so the column stays a column', () {
      expect(formatElapsed(161000), '2m 41s');
      expect(formatElapsed(1084000), '18m 04s');
    });

    test('hours and days', () {
      expect(formatElapsed(15120000), '4h 12m');
      expect(formatElapsed(3600000), '1h 00m');
      expect(formatElapsed(276480000), '3d 4h');
    });

    // D13a — MANDATORY. Every case above passes under the buggy per-tier
    // rounding that `ocr review` found in the mockup's reference fmt(), so
    // without these the documented ladder ships the bug.
    group('D13a carry cases', () {
      test('59.5s rounds up OUT of the seconds tier, not to "60s"', () {
        expect(formatElapsed(59500), '1m 00s');
        expect(formatElapsed(59900), '1m 00s');
      });

      test('a per-tier remainder must not produce "1m 60s"', () {
        expect(formatElapsed(119700), '2m 00s');
      });

      test(
        'the carry cascades a whole tier: 3599.7s is 1h 00m, not 59m 60s',
        () {
          expect(formatElapsed(3599700), '1h 00m');
        },
      );

      test('9.96s leaves the decimal branch rather than printing "10.0s"', () {
        expect(formatElapsed(9960), '10s');
      });
    });

    // D10b — a span that cannot be computed honestly is not rendered.
    group('D10b unrepresentable spans return null', () {
      test('negative', () => expect(formatElapsed(-3000), isNull));
      test('zero is representable', () => expect(formatElapsed(0), '0s'));
    });
  });

  group('elapsedMs — span arithmetic (SPEC-47 D1/D10b)', () {
    test('a finished span is end minus start', () {
      expect(elapsedMs(start: 1000, end: 3400), 2400);
    });

    test('end before start is unrepresentable, never clamped or absolute', () {
      expect(elapsedMs(start: 3000, end: 1000), isNull);
    });

    test('a null end means no terminal event was observed', () {
      expect(elapsedMs(start: 1000, end: null), isNull);
    });
  });
}
