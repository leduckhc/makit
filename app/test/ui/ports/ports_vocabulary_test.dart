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

  group('command line — argv[0] stripped, args kept', () {
    test('replaces an absolute argv[0] with its basename, keeping args', () {
      expect(
        portCommandLine(
          '/opt/homebrew/Cellar/node/26.5.1/bin/node vite --port 5173',
        ),
        'node vite --port 5173',
      );
    });

    test('a bare argv[0] with no args is just the basename', () {
      expect(portCommandLine('/usr/sbin/sshd'), 'sshd');
    });

    test('a relative command is returned untouched', () {
      expect(portCommandLine('postgres -D /data'), 'postgres -D /data');
    });

    test('preserves an argument that contains a slash', () {
      // Only argv[0] is shortened; a path *argument* is a fact about what the
      // process was told to do and must survive.
      expect(
        portCommandLine('/opt/homebrew/bin/node dist/serve.js'),
        'node dist/serve.js',
      );
    });
  });

  group('process line — pid, then age, then args', () {
    test('orders pid before uptime before the command', () {
      final s = portProcessLine(
        48211,
        '/opt/homebrew/Cellar/node/26.5.1/bin/node vite --port 5173',
        startedAt: nowMs - 41 * 60 * 1000,
        nowMs: nowMs,
      );
      // The whole point: in a fixed-width popover the tail ellipses, so the age
      // must sit ahead of the args or it is never seen (mockup §2a line 2).
      expect(s, 'pid 48211 · up 41m · node vite --port 5173');
      expect(s.indexOf('up 41m'), lessThan(s.indexOf('node vite')));
    });

    test('drops the age entirely when startedAt is unknown', () {
      // Absent stays absent — never "up 0m", never a zero-epoch "up 56y".
      expect(
        portProcessLine(51002, '/usr/sbin/sshd', startedAt: null, nowMs: nowMs),
        'pid 51002 · sshd',
      );
    });

    test('never carries the argv[0] directories', () {
      final s = portProcessLine(
        48211,
        '/opt/homebrew/Cellar/node/26.5.1/bin/node vite',
        startedAt: nowMs,
        nowMs: nowMs,
      );
      expect(s, isNot(contains('/opt/homebrew')));
    });
  });

  group('token tones — colour follows the verdict', () {
    test('a 2xx answer is ok, an HTTP error is a warning', () {
      expect(
        portHealthTone(health(PortHealthKind.ok, status: 200)),
        PortTone.ok,
      );
      expect(
        portHealthTone(health(PortHealthKind.httpError, status: 404)),
        PortTone.warn,
      );
    });

    test('a dead socket is an error, not a warning', () {
      // refused/timeout mean "you cannot use this", a different instruction
      // from 404's "it is up, just not mounted at /".
      expect(portHealthTone(health(PortHealthKind.refused)), PortTone.err);
      expect(portHealthTone(health(PortHealthKind.timeout)), PortTone.err);
    });

    test('an unprobed port is idle — never a fake verdict', () {
      expect(portHealthTone(null), PortTone.idle);
    });

    test('reach: exposed warns, tailnet is ok, loopback is idle', () {
      // Reach is the security token: the one that leaves this machine must be
      // the one that is not grey (mockup 116–118).
      expect(portReachTone(PortReach.exposed), PortTone.warn);
      expect(portReachTone(PortReach.tailnet), PortTone.ok);
      expect(portReachTone(PortReach.loopback), PortTone.idle);
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

  group('portCommandToken', () {
    test('reduces an absolute argv[0] to its basename', () {
      expect(
        portCommandToken('/opt/homebrew/Cellar/node/26.5.1/bin/node dist/x.js'),
        'node',
      );
    });

    test('leaves a bare command word alone', () {
      expect(portCommandToken('vite --port 5173'), 'vite');
    });

    test('never returns empty for a path-shaped or empty command', () {
      // A trailing slash would leave an empty basename, and an empty command
      // has no token at all. Neither may render as a blank slot on line 1.
      expect(portCommandToken('/usr/local/bin/ x'), '/usr/local/bin/');
      expect(portCommandToken(''), '');
    });
  });

  group('controls that already say what they do get no tooltip', () {
    test('Open and Copy URL have no tooltip', () {
      expect(portActionTooltip(PortAction.open), isNull);
      expect(portActionTooltip(PortAction.copyUrl), isNull);
    });
  });
}
