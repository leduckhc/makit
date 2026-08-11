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

  /// Review follow-up (PR #157): the fake only answered `session.listClosed`, so
  /// `session.close` fell through to a bare ack and the session stayed visible —
  /// the demo/no-server path could not exercise the feature at all.
  test(
    'session.close hides the session and session.reopen restores it',
    () async {
      final server = FakeServer();
      addTearDown(server.stop);

      // Subscribe BEFORE start(): start() schedules `_pushInitialState()` on a
      // 150ms timer, so a listener attached afterwards can miss that emission
      // entirely — and a firstWhere() added later would then wait for a second
      // snapshot that never comes.
      final snapshots = <List<Session>>[];
      final repoSnaps = <List<Map<String, dynamic>>>[];
      final acks = <String, Envelope>{};
      final sub = server.outgoing.listen((e) {
        if (e.body['kind'] == 'repos.snapshot') {
          repoSnaps.add((e.body['repos'] as List).cast<Map<String, dynamic>>());
        }
        if (e.body['kind'] == 'sessions.snapshot') {
          snapshots.add(
            WireCodec.decodeSessions(e.body['sessions']) ?? const [],
          );
        }
        if (e.t == MsgType.ack) acks[e.id] = e;
      });
      addTearDown(sub.cancel);

      // start() defers its first push behind a 150ms timer, so draining
      // microtasks is not enough here — real elapsed time is required.
      Future<void> settle() =>
          Future<void>.delayed(const Duration(milliseconds: 220));

      server.start();
      await settle();
      expect(
        snapshots,
        isNotEmpty,
        reason: 'start() broadcasts the active set',
      );
      final target = snapshots.last.first.id;

      server.send(
        Envelope(
          t: MsgType.cmd,
          id: 'c-close',
          body: {'kind': 'session.close', 'sessionId': target},
        ),
      );
      await settle();
      expect(
        snapshots.last.map((s) => s.id),
        isNot(contains(target)),
        reason: 'a closed session leaves the active snapshot',
      );

      server.send(
        Envelope(
          t: MsgType.cmd,
          id: 'c-list',
          body: const {'kind': 'session.listClosed'},
        ),
      );
      await settle();
      final listed = WireCodec.decodeSessions(
        acks['c-list']!.body['sessions'],
      )!;
      expect(
        listed.map((s) => s.id),
        contains(target),
        reason: 'and is reported by session.listClosed',
      );

      server.send(
        Envelope(
          t: MsgType.cmd,
          id: 'c-reopen',
          body: {'kind': 'session.reopen', 'sessionId': target},
        ),
      );
      await settle();
      expect(
        snapshots.last.map((s) => s.id),
        contains(target),
        reason: 'reopen puts it back in the active snapshot',
      );

      // A closed session must leave the REPO snapshot too, as the real server
      // does (`repo_service.ts` skips `s.closed`) — otherwise the demo keeps
      // counting it against its worktree.
      server.send(
        Envelope(
          t: MsgType.cmd,
          id: 'c-close-2',
          body: {'kind': 'session.close', 'sessionId': target},
        ),
      );
      await settle();
      final repoSessionIds = [
        for (final r in repoSnaps.last)
          for (final w
              in (r['worktrees'] as List? ?? const [])
                  .cast<Map<String, dynamic>>())
            for (final id in (w['sessionIds'] as List? ?? const []))
              id as String,
      ];
      expect(
        repoSessionIds,
        isNot(contains(target)),
        reason: 'a closed session leaves the repo snapshot too',
      );

      // A session seeded as closed must be reopenable, not inert: as a separate
      // literal, reopen acked and did nothing.
      server.send(
        Envelope(
          t: MsgType.cmd,
          id: 'c-reopen-seeded',
          body: const {'kind': 'session.reopen', 'sessionId': 's-closed-1'},
        ),
      );
      await settle();
      expect(
        snapshots.last.map((s) => s.id),
        contains('s-closed-1'),
        reason: 'a seeded closed fixture can be reopened',
      );
    },
  );

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
