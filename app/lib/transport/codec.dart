/// Pure wire codec for the app side — mirrors `server/src/protocol/codec.ts`.
///
/// Decodes incoming `event` envelopes (snapshots + session events) into typed
/// domain values, following the null-returning style of
/// [SessionEvent.fromJson]: malformed input yields `null` (logged + dropped by
/// the caller) and never throws. This is the single validation surface the
/// contract test locks in against the shared fixtures.
library;

import '../diagnostics/app_log.dart';
import '../store/metrics.dart';
import '../store/models.dart';
import '../store/ports.dart';
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

class ReposSnapshot extends Decoded {
  const ReposSnapshot(this.repos);
  final List<RepoInfo> repos;
}

class SessionEventFrame extends Decoded {
  const SessionEventFrame(this.event);
  final SessionEvent event;
}

class GithubBudgetFrame extends Decoded {
  const GithubBudgetFrame(this.budget);
  final GithubBudget budget;
}

/// A decoded `metrics.sample` frame (SPEC-37). [history] is the backfill sent
/// on the first frame after a watch begins; null on subsequent live frames.
class MetricsSampleFrame extends Decoded {
  const MetricsSampleFrame(this.sample, this.history);
  final MetricsSample sample;
  final List<MetricsSample>? history;
}

/// A decoded `ports.snapshot` frame (SPEC-41). A host-wide broadcast, like
/// `metrics.sample` — never a session event.
class PortsSnapshotFrame extends Decoded {
  const PortsSnapshotFrame(this.snapshot);
  final PortsSnapshot snapshot;
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
      appLog.warn('codec', 'dropped frame (decode threw: $e)');
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
      case 'repos.snapshot':
        final repos = decodeRepos(env.body['repos']);
        if (repos == null) {
          _warn('repos.snapshot');
          return null;
        }
        return ReposSnapshot(repos);
      case 'session.event':
        final event = decodeEvent(env.body['event']);
        if (event == null) {
          _warn('session.event');
          return null;
        }
        return SessionEventFrame(event);
      case 'github.budget':
        // Tolerant by contract: a missing bucket / null field must survive as
        // null (unmeasured ≠ empty), never take down the socket. Only a
        // non-map `budget` payload is unrecoverable.
        final raw = env.body['budget'];
        if (raw is! Map) {
          _warn('github.budget');
          return null;
        }
        return GithubBudgetFrame(
          GithubBudget.fromJson(Map<String, dynamic>.from(raw)),
        );
      case 'metrics.sample':
        // Tolerant like `github.budget`: a bad sample must `_warn` + drop, not
        // throw into the socket. Garbage scalars make `fromJson` return null.
        final rawSample = env.body['sample'];
        if (rawSample is! Map) {
          _warn('metrics.sample');
          return null;
        }
        final sample = MetricsSample.fromJson(
          Map<String, dynamic>.from(rawSample),
        );
        if (sample == null) {
          _warn('metrics.sample');
          return null;
        }
        final rawHistory = env.body['history'];
        final history = rawHistory is List
            ? rawHistory
                  .whereType<Map<dynamic, dynamic>>()
                  .map(
                    (m) => MetricsSample.fromJson(Map<String, dynamic>.from(m)),
                  )
                  .whereType<MetricsSample>()
                  .toList()
            : null;
        return MetricsSampleFrame(sample, history);
      case 'ports.snapshot':
        // Tolerant like `metrics.sample`: a malformed payload `_warn`s + drops
        // rather than throwing into the socket. Bad port entries inside a good
        // snapshot are dropped by `PortsSnapshot.fromJson`, not fatal here.
        final rawSnapshot = env.body['snapshot'];
        if (rawSnapshot is! Map) {
          _warn('ports.snapshot');
          return null;
        }
        final snapshot = PortsSnapshot.fromJson(
          Map<String, dynamic>.from(rawSnapshot),
        );
        if (snapshot == null) {
          _warn('ports.snapshot');
          return null;
        }
        return PortsSnapshotFrame(snapshot);
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
      final rawPane = j['pane'];
      final pane = rawPane is Map
          ? PaneInfo.fromJson(Map<String, dynamic>.from(rawPane))
          : null;
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
          pane: pane,
          pending: j['pending'] == true,
          pendingAgent: j['pendingAgent'] is String
              ? j['pendingAgent'] as String
              : null,
          branch: j['branch'] is String ? j['branch'] as String : null,
          worktreePath: j['worktreePath'] is String
              ? j['worktreePath'] as String
              : null,
          resumable: j['resumable'] == true,
          archived: j['archived'] == true,
          orphaned: j['orphaned'] == true,
          queued: decodeQueued(j['queued']),
        ),
      );
    }
    return out;
  }

  /// Decode a session's `queued` array (SPEC-35). Absent/malformed entries yield
  /// an empty queue rather than failing the whole snapshot: a session list is
  /// too important to drop over a pending-message chip.
  static List<QueuedMessage> decodeQueued(Object? raw) {
    if (raw is! List) return const [];
    final out = <QueuedMessage>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final q = QueuedMessage.fromJson(Map<String, dynamic>.from(entry));
      if (q != null) out.add(q);
    }
    return out;
  }

  /// Decode the `repos` array of a `repos.snapshot`, or null.
  static List<RepoInfo>? decodeRepos(Object? raw) {
    if (raw is! List) return null;
    final out = <RepoInfo>[];
    for (final entry in raw) {
      if (entry is! Map) return null;
      final repo = RepoInfo.fromJson(Map<String, dynamic>.from(entry));
      if (repo == null) return null;
      out.add(repo);
    }
    return out;
  }

  /// Decode a single `session.event` payload into a [SessionEvent], or null.
  static SessionEvent? decodeEvent(Object? raw) {
    if (raw is! Map) return null;
    return SessionEvent.fromJson(Map<String, dynamic>.from(raw));
  }

  static void _warn(String kind) {
    appLog.warn('codec', 'dropped malformed "$kind" frame');
  }
}
