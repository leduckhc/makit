// Demo-mode fixture coverage: the fake server has to seed the states the home
// screen can render, otherwise whole features are invisible in the demo (and to
// anyone evaluating the app with "Open with fake data").
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/store/fake_server.dart';
import 'package:makit/store/models.dart';
import 'package:makit/transport/codec.dart';
import 'package:makit/transport/protocol.dart';

/// Boots a fake server and returns the first `repos.snapshot` it pushes.
Future<List<RepoInfo>> _repos() async {
  final server = FakeServer();
  addTearDown(server.stop);
  final snapshot = server.outgoing.firstWhere(
    (e) => e.t == MsgType.event && e.body['kind'] == 'repos.snapshot',
  );
  server.start();
  final env = await snapshot.timeout(const Duration(seconds: 5));
  return WireCodec.decodeRepos(env.body['repos'])!;
}

/// Boots a fake server and returns the first `sessions.snapshot` it pushes.
Future<List<Session>> _sessionsSnapshot() async {
  final server = FakeServer();
  addTearDown(server.stop);
  final snapshot = server.outgoing.firstWhere(
    (e) => e.t == MsgType.event && e.body['kind'] == 'sessions.snapshot',
  );
  server.start();
  final env = await snapshot.timeout(const Duration(seconds: 5));
  return WireCodec.decodeSessions(env.body['sessions'])!;
}

void main() {
  test('seeds a worktree with no session', () async {
    final repos = await _repos();
    final all = [for (final r in repos) ...r.worktrees];

    expect(
      all.where((w) => w.sessionIds.isEmpty),
      isNotEmpty,
      reason: 'nothing exercises the session-less worktree row',
    );
  });

  test('seeds enough worktrees to need the "Show N more" cut', () async {
    final repos = await _repos();

    expect(
      repos.any((r) => r.worktrees.length > 5),
      isTrue,
      reason: 'no repo passes the five-worktree collapse threshold',
    );
  });

  test('seeds branch commit times', () async {
    final repos = await _repos();
    final all = [for (final r in repos) ...r.worktrees];

    expect(
      all.where((w) => w.committedAt != null),
      isNotEmpty,
      reason: 'branch age can never render',
    );
  });

  test('binds sessions to the worktree they run in', () async {
    // The session screen's PR chip resolves session -> worktree -> PR by path,
    // so a session without worktreePath can never show its PR.
    final sessions = await _sessionsSnapshot();
    final paths = [
      for (final r in await _repos()) ...r.worktrees,
    ].map((w) => w.path);

    final bound = sessions.where((s) => s.worktreePath != null);
    expect(bound, isNotEmpty, reason: 'no session names its worktree');
    for (final s in bound) {
      expect(paths, contains(s.worktreePath));
    }
  });

  test('answers session.listClosed with closed sessions', () async {
    final server = FakeServer();
    addTearDown(server.stop);
    final ack = server.outgoing.firstWhere((e) => e.t == MsgType.ack);
    server.start();
    server.send(
      Envelope(
        t: MsgType.cmd,
        id: 'c1',
        body: const {'kind': 'session.listClosed'},
      ),
    );
    final env = await ack.timeout(const Duration(seconds: 5));
    final sessions = WireCodec.decodeSessions(env.body['sessions']);

    expect(sessions, isNotNull);
    expect(sessions, isNotEmpty);
    expect(sessions!.every((s) => s.closed), isTrue);
  });
}
