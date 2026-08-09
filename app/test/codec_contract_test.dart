import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/transport/protocol.dart';

/// Load a fixture file shared byte-identically with the server
/// (`server/test/fixtures/*.json`).
List<dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync()) as List<dynamic>;

Envelope _envFromFixture(Map<String, dynamic> frame) =>
    Envelope.decode(jsonEncode(frame))!;

void main() {
  group('WireCodec contract (shared fixtures)', () {
    test('every frame fixture decodes to a typed Envelope', () {
      for (final raw in _fixture('frames.json')) {
        final frame = Map<String, dynamic>.from(raw as Map);
        expect(
          Envelope.decode(jsonEncode(frame)),
          isNotNull,
          reason: 'frame ${frame['t']} failed to decode',
        );
      }
    });

    test('projects.snapshot decodes to typed Project list', () {
      final snapshots = _fixture('snapshots.json');
      final env = _envFromFixture(
        Map<String, dynamic>.from(snapshots[0] as Map),
      );
      final decoded = WireCodec.decode(env);
      expect(decoded, isA<ProjectsSnapshot>());
      final projects = (decoded as ProjectsSnapshot).projects;
      expect(projects.length, 1);
      expect(projects.single.id, 'p1');
      expect(projects.single.name, 'makit');
      expect(projects.single.pinned, true);
    });

    test('sessions.snapshot decodes to typed Session list', () {
      final snapshots = _fixture('snapshots.json');
      final env = _envFromFixture(
        Map<String, dynamic>.from(snapshots[1] as Map),
      );
      final decoded = WireCodec.decode(env);
      expect(decoded, isA<SessionsSnapshot>());
      final sessions = (decoded as SessionsSnapshot).sessions;
      expect(sessions.length, 1);
      expect(sessions.single.id, 's1');
      expect(sessions.single.status, SessionStatus.running);
      expect(sessions.single.policy, ApprovalPolicy.askOnRisky);
    });

    test('ports.snapshot decodes to a typed PortsSnapshotFrame', () {
      final snapshots = _fixture('snapshots.json');
      final env = _envFromFixture(
        Map<String, dynamic>.from(snapshots[2] as Map),
      );
      final decoded = WireCodec.decode(env);
      expect(decoded, isA<PortsSnapshotFrame>());
      final snap = (decoded as PortsSnapshotFrame).snapshot;
      expect(snap.scanOk, true);
      expect(snap.scannedAt, 3000);
      // Select the port under test rather than asserting the fixture's total:
      // `snapshots.json` is a SHARED golden that later phases add ports to (P2b
      // appended an orphan and a collision), and a count assertion turns every
      // such addition into an unrelated failure here.
      final p = snap.ports.firstWhere((p) => p.port == 5173);
      expect(p.key, '48211:127.0.0.1:5173');
      expect(p.port, 5173);
      expect(p.address, '127.0.0.1');
      expect(p.reach, PortReach.loopback);
      expect(p.pid, 48211);
      expect(p.command, 'node vite --port 5173');
      expect(p.startedAt, 1000);
      expect(p.worktreePath, '/repo/makit-wt');
      expect(p.sessionId, 's1');
      expect(p.openUrl, 'http://127.0.0.1:5173');
      expect(p.health, isNotNull);
      expect(p.health!.kind, PortHealthKind.ok);
      expect(p.health!.status, 200);
      expect(p.health!.probedAt, 2000);
    });

    // T8 golden: the frozen contract carries one orphan-annotated and one
    // collision-annotated port. This reads the APP's mirror of
    // `snapshots.json`, which is kept byte-identical to the server's copy on
    // purpose — reaching across into `server/` would give the app a second
    // source of truth and a path that depends on the test's cwd.
    test('ports.snapshot T8 golden decodes orphan + collision fields', () {
      final snapshots = _fixture('snapshots.json');
      final env = _envFromFixture(
        Map<String, dynamic>.from(snapshots[2] as Map),
      );
      final decoded = WireCodec.decode(env);
      expect(decoded, isA<PortsSnapshotFrame>());
      final snap = (decoded as PortsSnapshotFrame).snapshot;
      expect(snap.ports.length, 4);

      final orphaned = snap.ports.firstWhere((p) => p.port == 5180);
      expect(orphaned.worktreePath, isNull);
      expect(orphaned.orphan, isNotNull);
      expect(orphaned.orphan!.formerBranch, 'feat/desktop-tabs');
      expect(orphaned.orphan!.formerWorktreePath, '/repo/makit-gone');
      expect(orphaned.orphan!.removedAt, 2500);
      expect(orphaned.collision, isNull);

      final collided = snap.ports.firstWhere((p) => p.port == 5174);
      expect(collided.worktreePath, '/repo/makit-wt');
      expect(collided.collision, isNotNull);
      expect(collided.collision!.withBranch, 'chore/deps');
      expect(collided.collision!.withWorktreePath, '/repo/makit-deps');
      expect(collided.orphan, isNull);
    });

    // T13 golden (P2c): the docker annotation is ownership, not reach (D13) —
    // the container's port stays `exposed` because that is what it is bound to.
    test('ports.snapshot T13 golden decodes the docker annotation', () {
      final snapshots = _fixture('snapshots.json');
      final env = _envFromFixture(
        Map<String, dynamic>.from(snapshots[2] as Map),
      );
      final snap = (WireCodec.decode(env) as PortsSnapshotFrame).snapshot;

      final container = snap.ports.firstWhere((p) => p.port == 5432);
      expect(container.docker, isNotNull);
      expect(container.docker!.container, 'chat-ui-db-1');
      expect(container.docker!.compose, '/repo/chat-ui/compose.yml');
      expect(container.reach, PortReach.exposed);
      expect(container.worktreePath, isNull);
    });

    test('every event fixture decodes to a typed SessionEvent', () {
      for (final raw in _fixture('events.json')) {
        final j = Map<String, dynamic>.from(raw as Map);
        final ev = WireCodec.decodeEvent(j);
        expect(ev, isNotNull, reason: 'event ${j['kind']} failed to decode');
        expect(ev!.kind.wire, j['kind']);
        expect(ev.seq, j['seq']);
        expect(ev.sessionId, j['sessionId']);
      }
    });

    test('session.event envelope routes through decode()', () {
      final frames = _fixture('frames.json');
      final eventFrame = frames.cast<Map<String, dynamic>>().firstWhere(
        (f) => f['kind'] == 'session.event',
      );
      final env = _envFromFixture(Map<String, dynamic>.from(eventFrame));
      final decoded = WireCodec.decode(env);
      expect(decoded, isA<SessionEventFrame>());
      expect((decoded as SessionEventFrame).event.kind, EventKind.userMessage);
    });

    test('malformed snapshot returns null, never throws', () {
      final env = Envelope(
        t: MsgType.event,
        id: 'x',
        body: {'kind': 'sessions.snapshot', 'sessions': 'not-a-list'},
      );
      expect(WireCodec.decode(env), isNull);
    });

    test('unknown frame kind returns null', () {
      final env = Envelope(
        t: MsgType.event,
        id: 'x',
        body: {'kind': 'totally.unknown'},
      );
      expect(WireCodec.decode(env), isNull);
    });
    test('valid-kind event with bad scalar seq returns null, never throws', () {
      final env = Envelope(
        t: MsgType.event,
        id: 'x',
        body: {
          'kind': 'session.event',
          'event': {
            'seq': 'not-a-number', // bad scalar
            'sessionId': 's1',
            'ts': 1,
            'kind': 'user.message',
            'payload': {'text': 'hi'},
          },
        },
      );
      expect(WireCodec.decode(env), isNull);
    });

    test('snapshot entry with bad-scalar lastActivityAt does not throw', () {
      final env = Envelope(
        t: MsgType.event,
        id: 'x',
        body: {
          'kind': 'sessions.snapshot',
          'sessions': [
            {
              'id': 's1',
              'projectId': 'p1',
              'agent': 'pi',
              'lastActivityAt': 'oops', // bad scalar, must not throw
            },
          ],
        },
      );
      final decoded = WireCodec.decode(env);
      expect(decoded, isA<SessionsSnapshot>());
      expect((decoded as SessionsSnapshot).sessions.single.lastActivityAt, 0);
    });
  });
}
