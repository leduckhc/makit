/// Pure wire codec for the app side — mirrors `server/src/protocol/codec.ts`.
///
/// Decodes incoming `event` envelopes (snapshots + session events) into typed
/// domain values, following the null-returning style of
/// [SessionEvent.fromJson]: malformed input yields `null` (logged + dropped by
/// the caller) and never throws. This is the single validation surface the
/// contract test locks in against the shared fixtures.
library;

import 'package:flutter/foundation.dart';

import '../store/models.dart';
import 'protocol.dart';

/// A decoded, typed view of an incoming `event` frame. The store's pure
/// reducer switches over these variants.
sealed class Decoded {
  const Decoded();
}

class ProjectsSnapshot extends Decoded {
  const ProjectsSnapshot(this.projects);
  final List<Project> projects;
}

class SessionsSnapshot extends Decoded {
  const SessionsSnapshot(this.sessions);
  final List<Session> sessions;
}

class SessionEventFrame extends Decoded {
  const SessionEventFrame(this.event);
  final SessionEvent event;
}

/// Stateless decoder. All methods return `null` on malformed input.
class WireCodec {
  const WireCodec._();

  /// Decode an `event` [Envelope] into a typed [Decoded], or null if the frame
  /// is unrecognized or malformed. Logs a warning on malformed known frames.
  static Decoded? decode(Envelope env) {
    try {
      return _decode(env);
    } catch (e) {
      // Belt-and-suspenders: the boundary must never throw into the frame
      // stream, whatever malformed shape arrives.
      debugPrint('[pino] WireCodec: dropped frame (decode threw: $e)');
      return null;
    }
  }

  static Decoded? _decode(Envelope env) {
    final kind = env.body['kind'];
    if (kind is! String) return null;
    switch (kind) {
      case 'projects.snapshot':
        final projects = decodeProjects(env.body['projects']);
        if (projects == null) {
          _warn('projects.snapshot');
          return null;
        }
        return ProjectsSnapshot(projects);
      case 'sessions.snapshot':
        final sessions = decodeSessions(env.body['sessions']);
        if (sessions == null) {
          _warn('sessions.snapshot');
          return null;
        }
        return SessionsSnapshot(sessions);
      case 'session.event':
        final event = decodeEvent(env.body['event']);
        if (event == null) {
          _warn('session.event');
          return null;
        }
        return SessionEventFrame(event);
      default:
        return null;
    }
  }

  /// Decode the `projects` array of a `projects.snapshot`, or null.
  static List<Project>? decodeProjects(Object? raw) {
    if (raw is! List) return null;
    final out = <Project>[];
    for (final entry in raw) {
      if (entry is! Map) return null;
      final j = Map<String, dynamic>.from(entry);
      final id = j['id'];
      final name = j['name'];
      final path = j['path'];
      if (id is! String || name is! String || path is! String) return null;
      out.add(
        Project(
          id: id,
          name: name,
          path: path,
          pinned: j['pinned'] is bool ? j['pinned'] as bool : false,
          lastActivityAt: j['lastActivityAt'] is num
              ? (j['lastActivityAt'] as num).toInt()
              : 0,
        ),
      );
    }
    return out;
  }

  /// Decode the `sessions` array of a `sessions.snapshot`, or null.
  static List<Session>? decodeSessions(Object? raw) {
    if (raw is! List) return null;
    final out = <Session>[];
    for (final entry in raw) {
      if (entry is! Map) return null;
      final j = Map<String, dynamic>.from(entry);
      final id = j['id'];
      final projectId = j['projectId'];
      final agent = j['agent'];
      if (id is! String || projectId is! String || agent is! String) {
        return null;
      }
      out.add(
        Session(
          id: id,
          projectId: projectId,
          agent: agent,
          title: j['title'] is String ? j['title'] as String : '',
          status: parseStatus(
            j['status'] is String ? j['status'] as String : 'idle',
          ),
          policy: parsePolicy(
            j['policy'] is String ? j['policy'] as String : 'ask-on-risky',
          ),
          lastActivityAt: j['lastActivityAt'] is num
              ? (j['lastActivityAt'] as num).toInt()
              : 0,
          lastPreview: j['lastPreview'] is String
              ? j['lastPreview'] as String
              : '',
        ),
      );
    }
    return out;
  }

  /// Decode a single `session.event` payload into a [SessionEvent], or null.
  static SessionEvent? decodeEvent(Object? raw) {
    if (raw is! Map) return null;
    return SessionEvent.fromJson(Map<String, dynamic>.from(raw));
  }

  static void _warn(String kind) {
    debugPrint('[pino] WireCodec: dropped malformed "$kind" frame');
  }
}
