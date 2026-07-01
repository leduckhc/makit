import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pino/store/models.dart';
import 'package:pino/transport/codec.dart';
import 'package:pino/transport/protocol.dart';

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
      final env = _envFromFixture(Map<String, dynamic>.from(snapshots[0] as Map));
      final decoded = WireCodec.decode(env);
      expect(decoded, isA<ProjectsSnapshot>());
      final projects = (decoded as ProjectsSnapshot).projects;
      expect(projects.length, 1);
      expect(projects.single.id, 'p1');
      expect(projects.single.name, 'pino');
      expect(projects.single.pinned, true);
    });

    test('sessions.snapshot decodes to typed Session list', () {
      final snapshots = _fixture('snapshots.json');
      final env = _envFromFixture(Map<String, dynamic>.from(snapshots[1] as Map));
      final decoded = WireCodec.decode(env);
      expect(decoded, isA<SessionsSnapshot>());
      final sessions = (decoded as SessionsSnapshot).sessions;
      expect(sessions.length, 1);
      expect(sessions.single.id, 's1');
      expect(sessions.single.status, SessionStatus.running);
      expect(sessions.single.policy, ApprovalPolicy.askOnRisky);
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
  });
}
