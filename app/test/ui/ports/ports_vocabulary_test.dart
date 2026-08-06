import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/ui/ports/ports_vocabulary.dart';

void main() {
  const nowMs = 100000;
  PortHealth health(PortHealthKind kind, {int? status, int probedAt = 96000}) =>
      PortHealth(kind: kind, status: status, probedAt: probedAt);

  group('health tooltip', () {
    test('every PortHealthKind has a non-empty sentence', () {
      for (final kind in PortHealthKind.values) {
        final s = portHealthTooltip(health(kind, status: 200), nowMs: nowMs);
        expect(s, isNotEmpty, reason: 'kind $kind produced an empty sentence');
      }
    });

    test('the health sentence carries the probe age', () {
      final s = portHealthTooltip(
        health(PortHealthKind.ok, status: 200, probedAt: 96000),
        nowMs: nowMs,
      );
      expect(s, contains('probed 4 s ago'));
    });

    test('an ok verdict names the status', () {
      final s = portHealthTooltip(
        health(PortHealthKind.ok, status: 200),
        nowMs: nowMs,
      );
      expect(s, contains('200'));
    });

    test(
      'an http-error with a null status still reads as a complete sentence',
      () {
        // The tolerant decoder permits a null status; the sentence must not
        // render `HTTP GET / →  — ...` with a hole where the code/reason go.
        final s = portHealthTooltip(
          health(PortHealthKind.httpError),
          nowMs: nowMs,
        );
        expect(s, startsWith('HTTP GET / → an error — '));
        expect(s, isNot(contains('→  ')));
        expect(s, isNot(contains('  —')));
      },
    );

    test('an http-error with an unrecognised status has no double space', () {
      final s = portHealthTooltip(
        health(PortHealthKind.httpError, status: 418),
        nowMs: nowMs,
      );
      expect(s, startsWith('HTTP GET / → 418 — '));
      expect(s, isNot(contains('418  ')));
    });

    test('absent health yields the not-probed sentence, no probe age', () {
      final s = portHealthTooltip(null, nowMs: nowMs);
      expect(s, isNotEmpty);
      expect(s.toLowerCase(), contains('not probed'));
      expect(s, isNot(contains('probed 0')));
    });
  });

  group('reach tooltip', () {
    test('every PortReach has a non-empty sentence', () {
      for (final reach in PortReach.values) {
        expect(portReachTooltip(reach), isNotEmpty);
      }
    });
  });

  group('scan-incomplete', () {
    test('has a non-empty sentence', () {
      expect(portsScanUnavailableTooltip('EPERM'), isNotEmpty);
      expect(portsScanUnavailableTooltip(null), isNotEmpty);
    });
  });

  group('uptime + pid/command', () {
    test('uptime reads "up Nm" and is empty when startedAt is absent', () {
      expect(portUptimeLabel(null, nowMs: nowMs), isEmpty);
      expect(portUptimeLabel(nowMs - 41 * 60 * 1000, nowMs: nowMs), 'up 41m');
    });

    test('pid + command are named', () {
      final s = portPidCommandLabel(48211, 'node vite --port 5173');
      expect(s, contains('48211'));
      expect(s, contains('node vite'));
    });
  });

  group('glyph semantic label — a word for every tinted state', () {
    test('serving/exposed/attention/unknown each name their state', () {
      expect(
        portsGlyphSemanticLabel(PortsGlyphState.serving, count: 3),
        contains('listening'),
      );
      expect(
        portsGlyphSemanticLabel(
          PortsGlyphState.exposed,
          count: 1,
        ).toLowerCase(),
        contains('exposed'),
      );
      expect(
        portsGlyphSemanticLabel(
          PortsGlyphState.attention,
          count: 2,
        ).toLowerCase(),
        contains('attention'),
      );
      expect(
        portsGlyphSemanticLabel(
          PortsGlyphState.unknown,
          count: 0,
        ).toLowerCase(),
        contains('unavailable'),
      );
    });
  });

  group('controls that already say what they do get no tooltip', () {
    test('Open and Copy URL have no tooltip', () {
      expect(portActionTooltip(PortAction.open), isNull);
      expect(portActionTooltip(PortAction.copyUrl), isNull);
    });
  });
}
