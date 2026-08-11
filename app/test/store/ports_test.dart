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

  group('SPEC-43 killPort', () {
    const target = PortKillTarget(
      address: '127.0.0.1',
      port: 5173,
      pid: 48211,
      startedAt: 1700000,
    );

    test(
      'sends the exact tuple the confirm displayed, and decodes the outcome',
      () async {
        final sent = <Map<String, dynamic>>[];
        final killer = PortsKiller((body) async {
          sent.add(body);
          return {'outcome': 'released', 'address': '127.0.0.1', 'port': 5173};
        });
        final outcome = await killer.kill(
          const PortKillTarget(
            address: '127.0.0.1',
            port: 5173,
            pid: 48211,
            startedAt: 1700000,
          ),
        );
        expect(outcome, PortKillOutcome.released);
        expect(sent, [
          {
            'kind': 'ports.kill',
            'address': '127.0.0.1',
            'port': 5173,
            'pid': 48211,
            'startedAt': 1700000,
          },
        ]);
      },
    );

    test('every server outcome decodes', () {
      expect(parsePortKillOutcome('released'), PortKillOutcome.released);
      expect(parsePortKillOutcome('force-killed'), PortKillOutcome.forceKilled);
      expect(parsePortKillOutcome('survived'), PortKillOutcome.survived);
      expect(parsePortKillOutcome('not_found'), PortKillOutcome.notFound);
      expect(
        parsePortKillOutcome('identity_mismatch'),
        PortKillOutcome.identityMismatch,
      );
      expect(parsePortKillOutcome('not_owned'), PortKillOutcome.notOwned);
      expect(
        parsePortKillOutcome('refused_protected'),
        PortKillOutcome.refusedProtected,
      );
      expect(parsePortKillOutcome('refused_self'), PortKillOutcome.refusedSelf);
      expect(
        parsePortKillOutcome('refused_session'),
        PortKillOutcome.refusedSession,
      );
      expect(
        parsePortKillOutcome('scan_unavailable'),
        PortKillOutcome.scanUnavailable,
      );
    });

    test('an unknown outcome is a FAILURE, never a silent success', () {
      // Decoding an unrecognised string as `released` would tell the user the
      // process is gone when the server said something we do not understand.
      expect(parsePortKillOutcome('teleported'), PortKillOutcome.failed);
      expect(parsePortKillOutcome(null), PortKillOutcome.failed);
      expect(parsePortKillOutcome(7), PortKillOutcome.failed);
      expect(PortKillOutcome.failed.releasedThePort, isFalse);
    });

    test('only released / force-killed count as the port being freed', () {
      expect(PortKillOutcome.released.releasedThePort, isTrue);
      expect(PortKillOutcome.forceKilled.releasedThePort, isTrue);
      for (final o in PortKillOutcome.values.where(
        (o) =>
            o != PortKillOutcome.released && o != PortKillOutcome.forceKilled,
      )) {
        expect(o.releasedThePort, isFalse, reason: '$o must not read as freed');
      }
    });

    test(
      'a rejected request degrades to failed rather than throwing',
      () async {
        final killer = PortsKiller(
          (_) async => throw StateError('bad_request'),
        );
        expect(await killer.kill(target), PortKillOutcome.failed);
      },
    );

    test(
      'PortKillTarget.of refuses a port whose startedAt is unknown (D1)',
      () {
        // Unverifiable identity ⇒ the UI must not offer a kill at all.
        expect(PortKillTarget.of(PortInfo.fromJson(_portJson())!), isNull);
        final withStart = PortInfo.fromJson(_portJson(startedAt: 1700000));
        final target = PortKillTarget.of(withStart!);
        expect(target, isNotNull);
        expect(target!.startedAt, 1700000);
        expect(target.pid, withStart.pid);
        expect(target.address, withStart.address);
        expect(target.port, withStart.port);
      },
    );
  });

  group('SPEC-44 watched ports', () {
    test('watched decodes, and defaults to false when absent', () {
      expect(PortInfo.fromJson(_portJson())!.watched, isFalse);
      expect(
        PortInfo.fromJson({..._portJson(), 'watched': true})!.watched,
        isTrue,
      );
      // Junk is not a watch: only a real `true` counts.
      expect(
        PortInfo.fromJson({..._portJson(), 'watched': 'yes'})!.watched,
        isFalse,
      );
    });

    test(
      'the toggle sends (worktreePath, port, on) — never the snapshot key',
      () async {
        final sent = <Map<String, dynamic>>[];
        final watcher = PortsWatchPort((body) async {
          sent.add(body);
          return const {};
        });
        expect(
          await watcher.set(worktreePath: '/wt/a', port: 5173, on: true),
          isTrue,
        );
        expect(sent, [
          {
            'kind': 'ports.watchPort',
            'worktreePath': '/wt/a',
            'port': 5173,
            'on': true,
          },
        ]);
      },
    );

    test('a failed toggle reports false so the UI can revert', () async {
      final watcher = PortsWatchPort((_) async => throw StateError('nope'));
      expect(
        await watcher.set(worktreePath: '/wt/a', port: 5173, on: true),
        isFalse,
      );
    });
  });

  group('SPEC-43 killOrphans (store)', () {
    test(
      'sends a payload-free command and decodes one outcome per endpoint',
      () async {
        final sent = <Map<String, dynamic>>[];
        final killer = PortsKiller((body) async {
          sent.add(body);
          return {
            'results': [
              {'outcome': 'released', 'address': '127.0.0.1', 'port': 5180},
              {'outcome': 'survived', 'address': '127.0.0.1', 'port': 5181},
            ],
          };
        });
        final outcomes = await killer.killOrphans();
        // No endpoints from the client: the orphan SET is the server's, which is
        // also what stops this becoming "kill an arbitrary list".
        expect(sent, [
          {'kind': 'ports.killOrphans'},
        ]);
        expect(outcomes, [PortKillOutcome.released, PortKillOutcome.survived]);
      },
    );

    test(
      'a malformed results list degrades to a single failure, never to empty',
      () async {
        // Empty would read as "no orphans left" — a success the server never said.
        expect(await PortsKiller((_) async => const {}).killOrphans(), [
          PortKillOutcome.failed,
        ]);
        expect(
          await PortsKiller((_) async => {'results': 'nope'}).killOrphans(),
          [PortKillOutcome.failed],
        );
        expect(
          await PortsKiller((_) async => throw StateError('x')).killOrphans(),
          [PortKillOutcome.failed],
        );
      },
    );

    test(
      'an unreadable entry inside a valid list is a failure, not a success',
      () async {
        final outcomes = await PortsKiller(
          (_) async => {
            'results': [
              {'outcome': 'released'},
              'garbage',
              {'nope': true},
            ],
          },
        ).killOrphans();
        expect(outcomes, [
          PortKillOutcome.released,
          PortKillOutcome.failed,
          PortKillOutcome.failed,
        ]);
      },
    );
  });

  group('SPEC-44 forwarding (store)', () {
    test(
      'ForwardGrant decodes what the client must have, and nothing less',
      () {
        final grant = ForwardGrant.fromJson({
          'grantId': 'G',
          'port': 5173,
          'path': '/forward/G/',
          'createdAt': 1,
          'expiresAt': 2,
          'browser': true,
        });
        expect(grant, isNotNull);
        expect(grant!.grantId, 'G');
        expect(grant.path, '/forward/G/');
        expect(grant.expiresAt, 2);
        expect(grant.browser, isTrue);

        // Any missing essential → null, so a half-grant can never be launched.
        for (final key in ['grantId', 'port', 'path', 'expiresAt']) {
          final partial = {
            'grantId': 'G',
            'port': 5173,
            'path': '/forward/G/',
            'expiresAt': 2,
          }..remove(key);
          expect(
            ForwardGrant.fromJson(partial),
            isNull,
            reason: 'missing $key',
          );
        }
        // `browser` is the weaker credential mode: only a literal true counts.
        expect(
          ForwardGrant.fromJson({
            'grantId': 'G',
            'port': 5173,
            'path': '/forward/G/',
            'expiresAt': 2,
            'browser': 'true',
          })!.browser,
          isFalse,
        );
      },
    );

    test('forward sends the tuple plus the explicit browser flag', () async {
      final sent = <Map<String, dynamic>>[];
      final forwarder = PortsForwarder((body) async {
        sent.add(body);
        return {
          'grant': {
            'grantId': 'G',
            'port': 5173,
            'path': '/forward/G/',
            'expiresAt': 9,
            'browser': true,
          },
        };
      });
      final result = await forwarder.forward(
        worktreePath: '/wt/a',
        port: 5173,
        browser: true,
      );
      expect(result.grant?.grantId, 'G');
      expect(result.refusal, isNull);
      expect(sent, [
        {
          'kind': 'ports.forward',
          'worktreePath': '/wt/a',
          'port': 5173,
          'browser': true,
        },
      ]);
    });

    test('a refusal surfaces the server REASON verbatim', () async {
      // The server errs with the actual rule ("database and shell ports are
      // never forwarded"), which is the only useful thing to show.
      final forwarder = PortsForwarder(
        (_) async =>
            throw StateError('database and shell ports are never forwarded'),
      );
      final result = await forwarder.forward(worktreePath: '/wt/a', port: 5432);
      expect(result.grant, isNull);
      expect(result.refusal, 'database and shell ports are never forwarded');
    });

    test(
      'an ack with no usable grant is a refusal, not a silent success',
      () async {
        final result = await PortsForwarder(
          (_) async => const {'grant': null},
        ).forward(worktreePath: '/wt/a', port: 5173);
        expect(result.grant, isNull);
        expect(result.refusal, isNotNull);
      },
    );

    test(
      'stop never throws, because a dead grant is already the goal',
      () async {
        await PortsForwarder((_) async => throw StateError('gone')).stop('G');
      },
    );
  });
}
