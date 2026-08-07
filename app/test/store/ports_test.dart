import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/codec.dart';

/// A minimal valid port map, so each test only overrides the field it probes.
Map<String, dynamic> _portJson({
  String key = '100:127.0.0.1:5173',
  Object? port = 5173,
  String address = '127.0.0.1',
  String reach = 'loopback',
  Object? pid = 100,
  String command = 'node vite',
  Object? startedAt,
  String? worktreePath,
  String? sessionId,
  Map<String, dynamic>? health,
  String? openUrl,
  Object? orphan,
  Object? collision,
}) => {
  'key': key,
  'port': port,
  'address': address,
  'reach': reach,
  'pid': pid,
  'command': command,
  'startedAt': ?startedAt,
  'worktreePath': ?worktreePath,
  'sessionId': ?sessionId,
  'health': ?health,
  'openUrl': ?openUrl,
  'orphan': ?orphan,
  'collision': ?collision,
};

PortsSnapshot _snap(List<Map<String, dynamic>> ports, {bool scanOk = true}) =>
    PortsSnapshot.fromJson({
      'ports': ports,
      'scannedAt': 3000,
      'scanOk': scanOk,
    })!;

void main() {
  group('PortInfo.fromJson tolerance', () {
    test('a non-numeric port drops the whole entry', () {
      expect(PortInfo.fromJson(_portJson(port: 'oops')), isNull);
    });

    test('a non-numeric pid drops the whole entry', () {
      expect(PortInfo.fromJson(_portJson(pid: 'oops')), isNull);
    });

    test('an unknown reach drops the entry (not silently coerced)', () {
      expect(PortInfo.fromJson(_portJson(reach: 'moon')), isNull);
    });

    test(
      'absent startedAt/worktreePath/sessionId/health/openUrl stay absent',
      () {
        final p = PortInfo.fromJson(_portJson())!;
        expect(p.startedAt, isNull);
        expect(p.worktreePath, isNull);
        expect(p.sessionId, isNull);
        expect(p.health, isNull);
        expect(p.openUrl, isNull);
      },
    );

    test('a non-numeric startedAt stays absent (never coerced to 0)', () {
      final p = PortInfo.fromJson(_portJson(startedAt: 'nope'))!;
      expect(p.startedAt, isNull);
    });

    test('a malformed health drops health but keeps the port', () {
      final p = PortInfo.fromJson(
        _portJson(health: {'kind': 'bogus', 'probedAt': 1}),
      );
      expect(p, isNotNull);
      expect(p!.health, isNull);
    });

    test('a health missing probedAt drops health but keeps the port', () {
      final p = PortInfo.fromJson(_portJson(health: {'kind': 'ok'}));
      expect(p, isNotNull);
      expect(p!.health, isNull);
    });

    test('health status stays absent when not sent', () {
      final p = PortInfo.fromJson(
        _portJson(health: {'kind': 'refused', 'probedAt': 2000}),
      )!;
      expect(p.health!.kind, PortHealthKind.refused);
      expect(p.health!.status, isNull);
    });
  });

  group('orphan/collision tolerance (SPEC-42 D10/D12)', () {
    test('a well-formed orphan parses all three fields', () {
      final p = PortInfo.fromJson(
        _portJson(
          worktreePath: null,
          orphan: {
            'formerBranch': 'feat/desktop-tabs',
            'formerWorktreePath': '/repo/gone',
            'removedAt': 2500,
          },
        ),
      )!;
      expect(p.orphan, isNotNull);
      expect(p.orphan!.formerBranch, 'feat/desktop-tabs');
      expect(p.orphan!.formerWorktreePath, '/repo/gone');
      expect(p.orphan!.removedAt, 2500);
      expect(p.collision, isNull);
    });

    test('a well-formed collision parses both fields', () {
      final p = PortInfo.fromJson(
        _portJson(
          collision: {
            'withBranch': 'chore/deps',
            'withWorktreePath': '/repo/deps',
          },
        ),
      )!;
      expect(p.collision, isNotNull);
      expect(p.collision!.withBranch, 'chore/deps');
      expect(p.collision!.withWorktreePath, '/repo/deps');
    });

    test('a non-map orphan drops to null but keeps the port', () {
      final p = PortInfo.fromJson(_portJson(orphan: 'oops'));
      expect(p, isNotNull);
      expect(p!.orphan, isNull);
    });

    test('a non-map collision drops to null but keeps the port', () {
      final p = PortInfo.fromJson(_portJson(collision: 42));
      expect(p, isNotNull);
      expect(p!.collision, isNull);
    });

    test('a bad-scalar removedAt stays absent (never coerced to 0 — D10)', () {
      // The fabrication D10 exists to prevent: a zeroed date would render as an
      // epoch string / "removed 56y ago", the exact "up 56y" lie the feature
      // refuses. Absent must stay absent.
      final p = PortInfo.fromJson(
        _portJson(
          worktreePath: null,
          orphan: {'formerBranch': 'feat/x', 'removedAt': 'nope'},
        ),
      )!;
      expect(p.orphan, isNotNull);
      expect(p.orphan!.formerBranch, 'feat/x');
      expect(p.orphan!.removedAt, isNull);
    });

    test('an empty orphan object is still an orphan (branch/date unknown)', () {
      // The annotation existing is what marks the port orphaned; the fields
      // inside are individually optional (the port IS orphaned even when we
      // know neither its branch nor when it went).
      final p = PortInfo.fromJson(
        _portJson(worktreePath: null, orphan: <String, dynamic>{}),
      )!;
      expect(p.orphan, isNotNull);
      expect(p.orphan!.formerBranch, isNull);
      expect(p.orphan!.formerWorktreePath, isNull);
      expect(p.orphan!.removedAt, isNull);
    });

    test('a bad-scalar withBranch stays absent (never coerced)', () {
      final p = PortInfo.fromJson(
        _portJson(collision: {'withBranch': 7, 'withWorktreePath': '/repo/d'}),
      )!;
      expect(p.collision, isNotNull);
      expect(p.collision!.withBranch, isNull);
      expect(p.collision!.withWorktreePath, '/repo/d');
    });

    test('orphan/collision stay absent when not sent', () {
      final p = PortInfo.fromJson(_portJson())!;
      expect(p.orphan, isNull);
      expect(p.collision, isNull);
    });
  });

  group('PortsSnapshot.fromJson', () {
    test('drops malformed entries but keeps the good ones', () {
      final snap = PortsSnapshot.fromJson({
        'ports': [
          _portJson(key: 'a', port: 5173),
          _portJson(key: 'b', port: 'bad'),
          _portJson(key: 'c', port: 5174),
        ],
        'scannedAt': 3000,
        'scanOk': true,
      })!;
      expect(snap.ports.length, 2);
    });

    test('a payload with no ports key is dropped, not fabricated empty', () {
      // A truncated frame must not decode as "healthy and empty": absence is
      // never coerced into a value (the BudgetBucket/SurfaceMetrics rule). The
      // codec then _warns + drops it, leaving the previous state intact.
      expect(
        PortsSnapshot.fromJson({'scannedAt': 3000, 'scanOk': true}),
        isNull,
      );
    });

    test('a payload with no scanOk is dropped, not fabricated healthy', () {
      expect(
        PortsSnapshot.fromJson({
          'scannedAt': 3000,
          'ports': const <Map<String, dynamic>>[],
        }),
        isNull,
      );
    });

    test('a non-bool scanOk is dropped (never coerced to true)', () {
      expect(
        PortsSnapshot.fromJson({
          'scannedAt': 3000,
          'ports': const <Map<String, dynamic>>[],
          'scanOk': 'yes',
        }),
        isNull,
      );
    });

    test('scanError stays absent when not sent, present when sent', () {
      final ok = _snap(const []);
      expect(ok.scanError, isNull);
      final bad = PortsSnapshot.fromJson({
        'ports': const <Map<String, dynamic>>[],
        'scannedAt': 3000,
        'scanOk': false,
        'scanError': 'EPERM',
      })!;
      expect(bad.scanOk, false);
      expect(bad.scanError, 'EPERM');
    });
  });

  group('reducer', () {
    test('PortsSnapshotFrame latest-wins', () {
      var state = StoreState.empty();
      expect(state.ports, isNull);
      state = reduce(state, PortsSnapshotFrame(_snap([_portJson()])));
      expect(state.ports!.ports.length, 1);
      state = reduce(state, PortsSnapshotFrame(_snap(const [])));
      expect(state.ports!.ports, isEmpty);
    });
  });

  group('portsForWorktree', () {
    test('filters by worktreePath and sorts by port then pid', () {
      final snap = _snap([
        _portJson(key: 'x', port: 5175, pid: 20, worktreePath: '/wt'),
        _portJson(key: 'y', port: 5173, pid: 30, worktreePath: '/wt'),
        _portJson(key: 'z', port: 5173, pid: 10, worktreePath: '/wt'),
        _portJson(key: 'o', port: 4000, pid: 1, worktreePath: '/other'),
      ]);
      final list = portsForWorktree(snap, '/wt');
      expect(list.map((p) => p.port).toList(), [5173, 5173, 5175]);
      // Same port ⇒ ascending pid.
      expect(list[0].pid, 10);
      expect(list[1].pid, 30);
    });

    test('a null snapshot yields an empty list', () {
      expect(portsForWorktree(null, '/wt'), isEmpty);
    });
  });

  group('glyph-state ladder', () {
    PortsGlyphState state(
      List<Map<String, dynamic>> ports, {
      bool scanOk = true,
    }) => portsGlyphState(_snap(ports, scanOk: scanOk), '/wt');

    test('null snapshot ⇒ none', () {
      expect(portsGlyphState(null, '/wt'), PortsGlyphState.none);
    });

    test('scanOk:false ⇒ unknown', () {
      expect(state(const [], scanOk: false), PortsGlyphState.unknown);
    });

    test('no ports for the worktree ⇒ none', () {
      expect(state([_portJson(worktreePath: '/other')]), PortsGlyphState.none);
    });

    test('a refused port ⇒ attention', () {
      expect(
        state([
          _portJson(
            worktreePath: '/wt',
            health: {'kind': 'refused', 'probedAt': 1},
          ),
        ]),
        PortsGlyphState.attention,
      );
    });

    test('an exposed port (no attention) ⇒ exposed', () {
      expect(
        state([_portJson(worktreePath: '/wt', reach: 'exposed')]),
        PortsGlyphState.exposed,
      );
    });

    test('a healthy loopback port ⇒ serving', () {
      expect(state([_portJson(worktreePath: '/wt')]), PortsGlyphState.serving);
    });

    test('attention beats exposed', () {
      expect(
        state([
          _portJson(worktreePath: '/wt', reach: 'exposed'),
          _portJson(
            key: 'z',
            worktreePath: '/wt',
            health: {'kind': 'timeout', 'probedAt': 1},
          ),
        ]),
        PortsGlyphState.attention,
      );
    });
  });

  group('PortsWatch ref-counting', () {
    test('sends one {on:true} for N holders and one {on:false} on release', () {
      final calls = <bool>[];
      final watch = PortsWatch(calls.add);
      watch.watch();
      watch.watch();
      watch.watch();
      expect(calls, [true]);
      watch.release();
      watch.release();
      expect(calls, [true]);
      watch.release();
      expect(calls, [true, false]);
    });

    test('a release with no live watchers is a no-op', () {
      final calls = <bool>[];
      PortsWatch(calls.add).release();
      expect(calls, isEmpty);
    });
  });
}
