/// In-process fake "server" used for M0 development so UI work doesn't block
/// on the real Node/TS server. Behaviour is the bare minimum to exercise the
/// chat UI: seeds two projects with sessions, replays a scripted agent
/// transcript with delays, handles `send.message`.
///
/// Delete (or gate behind a `--dart-define`) once the real server is wired up.
library;

import 'dart:async';
import 'dart:convert';

import 'package:ulid/ulid.dart';

import '../transport/protocol.dart';

class FakeServer {
  final _outCtrl = StreamController<Envelope>.broadcast();
  Stream<Envelope> get outgoing => _outCtrl.stream;

  final Map<String, _FakeSession> _sessions = {};
  final Map<String, String> _addedProjects = {};
  Timer? _seedTimer;
  Timer? _metricsTimer;
  int _metricsTick = 0;

  void start() {
    _seed();
    // Push initial state shortly after connect so UI has something to show.
    _seedTimer = Timer(const Duration(milliseconds: 150), _pushInitialState);
  }

  void stop() {
    _seedTimer?.cancel();
    _metricsTimer?.cancel();
    _outCtrl.close();
  }

  void send(Envelope env) {
    switch (env.t) {
      case MsgType.hello:
        _emit(Envelope(t: MsgType.helloAck, id: env.id, body: {'ok': true}));
      case MsgType.sub:
        final sid = env.body['sessionId'] as String?;
        if (sid != null) _replaySession(sid);
        _emit(Envelope(t: MsgType.ack, id: env.id));
      case MsgType.cmd:
        _handleCmd(env);
      case MsgType.ping:
        _emit(Envelope(t: MsgType.pong, id: env.id, body: env.body));
      default:
        break;
    }
  }

  // ---- domain --------------------------------------------------------------

  void _seed() {
    const p1 = 'proj-makit';
    const p2 = 'proj-cmux';

    _sessions['s-codex-1'] = _FakeSession(
      id: 's-codex-1',
      projectId: p1,
      projectName: 'makit',
      projectPath: '/Users/le/Work/Vibe/makit',
      agent: 'codex',
      title: 'wire up pairing screen',
      preview: 'Patched lib/pairing/pairing_screen.dart, ran tests.',
      branch: 'wire-up-pairing-screen',
    )..events.addAll(_scriptCodex('s-codex-1'));

    _sessions['s-pi-1'] = _FakeSession(
      id: 's-pi-1',
      projectId: p1,
      projectName: 'makit',
      projectPath: '/Users/le/Work/Vibe/makit',
      agent: 'pi',
      title: 'review architecture doc',
      preview: 'Reviewed docs/ARCHITECTURE.md, suggested 3 changes.',
    )..events.addAll(_scriptPi('s-pi-1'));

    _sessions['s-claude-1'] = _FakeSession(
      id: 's-claude-1',
      projectId: p2,
      projectName: 'cmux',
      projectPath: '/Users/le/Work/Vibe/cmux',
      agent: 'claude',
      title: 'fix tab drag-and-drop',
      preview: 'Editing Sources/Tabs/TabBar.swift',
      status: 'running',
      branch: 'fix-tab-drag-and-drop',
    )..events.addAll(_scriptClaude('s-claude-1'));

    // Cold-start content for the Closed view (SPEC-29). These live in
    // [_sessions] like every other session: as separate literals they could be
    // listed but never reopened, and never appeared in any snapshot.
    _sessions['s-closed-1'] = _FakeSession(
      id: 's-closed-1',
      projectId: p1,
      projectName: 'makit',
      projectPath: '/Users/le/Work/Vibe/makit',
      agent: 'pi',
      title: 'draft release notes',
      preview: 'Wrote CHANGELOG.md for 0.4.0.',
      status: 'exited',
      branch: 'draft-release-notes',
    )..closed = true;
    // No worktree for this one in [_pushRepos], which is what makes it render
    // the "worktree removed" chip.
    _sessions['s-closed-2'] = _FakeSession(
      id: 's-closed-2',
      projectId: p2,
      projectName: 'cmux',
      projectPath: '/Users/le/Work/Vibe/cmux',
      agent: 'claude',
      title: 'investigate tab flicker',
      preview: 'Traced it to the snapshot boundary.',
      status: 'exited',
      branch: 'investigate-tab-flicker',
    )..closed = true;
  }

  void _pushInitialState() {
    _pushProjects();
    _pushRepos();
    _pushSessions();
    _pushBudget();
  }

  void _pushProjects() {
    final projects = <String, Map<String, dynamic>>{};
    for (final s in _sessions.values.where((s) => !s.closed)) {
      projects.putIfAbsent(
        s.projectId,
        () => {
          'id': s.projectId,
          'name': s.projectName,
          'path': s.projectPath,
          'pinned': true,
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      );
    }
    for (final entry in _addedProjects.entries) {
      projects.putIfAbsent(
        entry.key,
        () => {
          'id': entry.key,
          'name': entry.value.split('/').where((s) => s.isNotEmpty).last,
          'path': entry.value,
          'pinned': false,
          'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        },
      );
    }
    _emit(
      Envelope(
        t: MsgType.event,
        id: Ulid().toString(),
        body: {
          'kind': 'projects.snapshot',
          'projects': projects.values.toList(),
        },
      ),
    );
  }

  /// Repo-centric snapshot: two demo repos, each with a primary worktree plus
  /// a feature-branch worktree carrying diff stats / an open PR, and (for the
  /// first repo) a tail of quiet branches so the demo also shows what a busy
  /// checkout looks like — session-less rows, the "Show N more" cut and branch
  /// ages.
  void _pushRepos() {
    final byProject = <String, List<_FakeSession>>{};
    for (final s in _sessions.values.where((s) => !s.closed)) {
      byProject.putIfAbsent(s.projectId, () => []).add(s);
    }
    for (final entry in _addedProjects.entries) {
      byProject.putIfAbsent(entry.key, () => []);
    }

    final repos = <Map<String, dynamic>>[];
    byProject.forEach((pid, sess) {
      final first = sess.isNotEmpty
          ? sess.first
          : _FakeSession(
              id: '',
              projectId: pid,
              projectName: _addedProjects[pid]!
                  .split('/')
                  .where((s) => s.isNotEmpty)
                  .last,
              projectPath: _addedProjects[pid]!,
              agent: 'pi',
              title: '',
              preview: '',
            );
      final repoPath = first.projectPath;
      // Split sessions across two worktrees for a realistic demo.
      final primaryIds = sess
          .where((s) => s.branch == null)
          .map((s) => s.id)
          .toList();
      final featureSessions = sess.where((s) => s.branch != null).toList();
      final worktrees = <Map<String, dynamic>>[
        {
          'id': repoPath,
          'path': repoPath,
          'branch': 'main',
          'isPrimary': true,
          'insertions': 0,
          'deletions': 0,
          'filesChanged': 0,
          'sessionIds': primaryIds,
          'committedAt': _agoMs(const Duration(hours: 5)),
        },
      ];
      final featBranches = <String, List<String>>{};
      for (final s in featureSessions) {
        featBranches.putIfAbsent(s.branch!, () => []).add(s.id);
      }
      var i = 0;
      featBranches.forEach((branch, ids) {
        i++;
        worktrees.add({
          'id': '$repoPath/.wt/$branch',
          'path': '$repoPath/.wt/$branch',
          'branch': branch,
          'isPrimary': false,
          'insertions': 40 * i + 2,
          'deletions': 6 * i,
          'filesChanged': 2 + i,
          'sessionIds': ids,
          'committedAt': _agoMs(Duration(minutes: 12 * i)),
          if (i == 1)
            'pr': {
              'number': 41 + i,
              'url': 'https://github.com/demo/pull/${41 + i}',
              'state': 'OPEN',
              'title': branch,
              'isDraft': false,
              'mergeable': 'MERGEABLE',
              'mergeStateStatus': 'CLEAN',
              'checkRollup': 'pending',
              'checks': [
                {
                  'name': 'test',
                  'bucket': 'pass',
                  'workflowName': 'CI',
                  'detailsUrl': 'https://github.com/demo/actions/1',
                },
                {
                  'name': 'lint',
                  'bucket': 'pass',
                  'workflowName': 'CI',
                  'detailsUrl': 'https://github.com/demo/actions/2',
                },
                {
                  'name': 'e2e',
                  'bucket': 'pending',
                  'workflowName': 'E2E',
                  'detailsUrl': 'https://github.com/demo/actions/3',
                },
              ],
            },
        });
      });

      repos.add({
        'id': pid,
        'name': first.projectName,
        'path': repoPath,
        'pinned': true,
        'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
        'isGitRepo': true,
        'defaultBranch': 'main',
        'currentBranch': 'main',
        'worktrees': [...worktrees, ..._quietWorktrees(pid, repoPath)],
      });
    });

    _emit(
      Envelope(
        t: MsgType.event,
        id: Ulid().toString(),
        body: {'kind': 'repos.snapshot', 'repos': repos},
      ),
    );
  }

  /// Epoch-ms for "[ago] before now" — keeps the seeded timestamps readable at
  /// the call site instead of raw arithmetic.
  int _agoMs(Duration ago) =>
      DateTime.now().subtract(ago).millisecondsSinceEpoch;

  /// Quiet branches with no sessions, added to the *first* demo repo only: real
  /// checkouts accumulate stale worktrees, and without them the demo shows
  /// neither a session-less row, the five-worktree "Show N more" cut, nor a
  /// spread of branch ages. One carries uncommitted work so it also demonstrates
  /// why a branch with no session is still worth listing.
  List<Map<String, dynamic>> _quietWorktrees(
    String projectId,
    String repoPath,
  ) {
    if (projectId != 'proj-makit') return const [];
    const branches = [
      ('tidy-composer-spacing', 18, 4, 2, Duration(days: 2)),
      ('spike-offline-cache', 0, 0, 0, Duration(days: 9)),
      ('bump-deps', 3, 3, 1, Duration(days: 34)),
      ('old-experiment', 0, 0, 0, Duration(days: 420)),
    ];
    return [
      for (final (branch, ins, del, files, age) in branches)
        {
          'id': '$repoPath/.wt/$branch',
          'path': '$repoPath/.wt/$branch',
          'branch': branch,
          'isPrimary': false,
          'insertions': ins,
          'deletions': del,
          'filesChanged': files,
          'uncommittedFiles': files,
          'sessionIds': const <String>[],
          'committedAt': _agoMs(age),
        },
    ];
  }


  void _pushSessions() {
    _emit(
      Envelope(
        t: MsgType.event,
        id: Ulid().toString(),
        body: {
          'kind': 'sessions.snapshot',
          'sessions': _sessions.values
              .where((s) => !s.closed)
              .map(
                (s) => {
                  'id': s.id,
                  'projectId': s.projectId,
                  'agent': s.agent,
                  'title': s.title,
                  'status': s.status,
                  'policy': 'ask-on-risky',
                  'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
                  'lastPreview': s.preview,
                  'pending': s.pending,
                  if (s.branch != null) 'branch': s.branch,
                  // Path of the worktree this session runs in, matching the
                  // ids built in [_pushRepos]. Surfaces that resolve
                  // session -> worktree (the PR chip, the composer's git
                  // hints) are dead without it.
                  if (!s.pending)
                    'worktreePath': s.branch == null
                        ? s.projectPath
                        : '${s.projectPath}/.wt/${s.branch}',
                },
              )
              .toList(),
        },
      ),
    );
  }

  /// Emit one plausible `github.budget` frame so the footer icon + popover have
  /// data on the fake path. A `warm` level with an active throttle exercises
  /// the interesting rendering path (banner, dimmed pills) rather than the
  /// boring healthy one.
  void _pushBudget() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _emit(
      Envelope(
        t: MsgType.event,
        id: Ulid().toString(),
        body: {
          'kind': 'github.budget',
          'budget': {
            'buckets': {
              'core': {
                'limit': 5000,
                'remaining': 1769,
                'resetAt': now + 1080000,
                'mine': 2100,
                'others': 1131,
              },
              'graphql': {
                'limit': 5000,
                'remaining': 4188,
                'resetAt': now + 1080000,
                'mine': 300,
                'others': 512,
              },
              'search': {
                'limit': 30,
                'remaining': 24,
                'resetAt': now + 38000,
                'mine': 0,
                'others': 6,
              },
            },
            'burnPerHour': 340,
            'msUntilEmpty': 1080000,
            'level': 'warm',
            'throttles': ['unresolved counts on demand', 'poll 30s'],
            'retryAfterMs': null,
            'measuredAt': now,
            'history': [
              for (var i = 0; i < 60; i++)
                {'mine': (i * 3) % 11, 'others': i % 4},
            ],
            'stats': {'execs': 412, 'cacheHits': 1893},
          },
        },
      ),
    );
  }

  /// Start emitting a plausible `metrics.sample` about once a second so widget
  /// tests and the keyless stub loop render real charts (SPEC-37). The first
  /// frame carries a short `history` backfill, matching the real server.
  void _startMetrics() {
    _metricsTimer?.cancel();
    _metricsTick = 0;
    final history = [for (var i = 30; i > 0; i--) _metricsSample(ago: i)];
    _emitMetrics(history: history);
    _metricsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _emitMetrics(),
    );
  }

  void _stopMetrics() {
    _metricsTimer?.cancel();
    _metricsTimer = null;
  }

  void _emitMetrics({List<Map<String, dynamic>>? history}) {
    _emit(
      Envelope(
        t: MsgType.event,
        id: Ulid().toString(),
        body: {
          'kind': 'metrics.sample',
          'sample': _metricsSample(),
          'history': ?history,
        },
      ),
    );
  }

  /// One plausible sample. [ago] shifts the timestamp back N seconds for the
  /// history backfill; CPU wobbles a little so charts are not flat lines.
  Map<String, dynamic> _metricsSample({int ago = 0}) {
    final tick = _metricsTick++;
    final now = DateTime.now().millisecondsSinceEpoch - ago * 1000;
    double wobble(double base, double amp) =>
        base + amp * ((tick % 7) / 7.0 - 0.5);
    return {
      'ts': now,
      'app': {
        'pid': 4242,
        'rssBytes': 180 * 1024 * 1024,
        'cpuPercent': wobble(2.1, 1.4),
        'cpuSeconds': 12.4 + tick * 0.02,
      },
      'server': {
        'pid': 4201,
        'rssBytes': 96 * 1024 * 1024,
        'cpuPercent': wobble(0.8, 0.6),
        'cpuSeconds': 5.1 + tick * 0.01,
        'eventLoop': {'p50': wobble(1.2, 0.4), 'p99': wobble(3.4, 1.1)},
      },
      'agents': [
        {
          'pid': 5001,
          'rssBytes': 220 * 1024 * 1024,
          'cpuPercent': wobble(6.5, 5.0),
          'cpuSeconds': 44.2 + tick * 0.08,
          'sessionId': 's-codex-1',
          'label': 'codex · wire up pairing screen',
          'inTurn': tick.isEven,
          'procs': 3,
          'uptimeMs': 60000 + tick * 1000,
        },
      ],
      'wire': {
        'inBytesPerSec': wobble(1400, 900),
        'outBytesPerSec': wobble(3200, 1800),
        'framesPerSec': wobble(2.0, 1.5),
      },
      // Only every 6th tick refreshes storage; null otherwise.
      'storage': tick % 6 == 0 ? {'eventLogBytes': 2 * 1024 * 1024} : null,
      'sampler': {'cpuPercent': wobble(0.3, 0.2), 'rssBytes': 4 * 1024 * 1024},
      'turnActive': tick.isEven,
      'procTableOk': true,
    };
  }

  /// Ports the demo has "killed" — they stop appearing in the snapshot, so the
  /// kill visibly works in demo mode.
  final Set<int> _killedPorts = {};

  /// Ports the demo user has asked to be told about (SPEC-44 D7).
  final Set<int> _watchedPorts = {5173};

  /// Emit one plausible `ports.snapshot`, covering every state the ports UI can
  /// render so demo mode exercises the whole surface (SPEC-41 → SPEC-44):
  ///
  ///  * `:5173 vite`   — healthy, owned by the first feature-branch worktree, so
  ///                     a glyph lights on that row. Watched by default, and the
  ///                     one port a browser forward is offered for.
  ///  * `:5175 vite`   — owned but **refused**: the wedged zombie SPEC-43's kill
  ///                     exists for. No `openUrl`, so no forward is offered.
  ///  * `:9787 serve`  — wildcard-bound, `exposed`, 404 — the security read.
  ///  * `:5432 postgres` — published by a docker container (SPEC-42 D13): the row
  ///                     names the CONTAINER, and `reach` still says `exposed`.
  ///  * `:5180`/`:5181` — orphans whose worktree is gone, which is what makes the
  ///                     orphans section and `Kill all orphans (2)` appear.
  void _pushPorts() {
    final feature = _sessions.values.firstWhere(
      (s) => s.branch != null,
      orElse: () => _sessions.values.first,
    );
    final wtPath = feature.branch == null
        ? feature.projectPath
        : '${feature.projectPath}/.wt/${feature.branch}';
    final now = DateTime.now().millisecondsSinceEpoch;

    Map<String, dynamic> port({
      required int number,
      required String key,
      required String command,
      String address = '127.0.0.1',
      String reach = 'loopback',
      required int pid,
      required int upMs,
      String? worktreePath,
      String? sessionId,
      Map<String, dynamic>? health,
      String? openUrl,
      Map<String, dynamic>? orphan,
      Map<String, dynamic>? docker,
    }) => {
      'key': key,
      'port': number,
      'address': address,
      'reach': reach,
      'pid': pid,
      'command': command,
      'startedAt': now - upMs,
      // Absent, never null: the app's decoder treats absence as "not known",
      // which is the whole point of these fields (SPEC-41).
      'worktreePath': ?worktreePath,
      'sessionId': ?sessionId,
      'health': ?health,
      'openUrl': ?openUrl,
      'orphan': ?orphan,
      'docker': ?docker,
      if (_watchedPorts.contains(number)) 'watched': true,
    };

    final all = <Map<String, dynamic>>[
      port(
        number: 5173,
        key: '48211:127.0.0.1:5173',
        command: 'node vite --port 5173',
        pid: 48211,
        upMs: 41 * 60 * 1000,
        worktreePath: wtPath,
        sessionId: feature.id,
        health: {'kind': 'ok', 'status': 200, 'probedAt': now - 4000},
        openUrl: 'http://127.0.0.1:5173',
      ),
      port(
        number: 5175,
        key: '51330:127.0.0.1:5175',
        command: 'node vite --port 5175',
        pid: 51330,
        upMs: 6 * 60 * 60 * 1000,
        worktreePath: wtPath,
        health: {'kind': 'refused', 'probedAt': now - 3000},
      ),
      port(
        number: 9787,
        key: '47120:0.0.0.0:9787',
        command: 'node dist/serve.js',
        address: '0.0.0.0',
        reach: 'exposed',
        pid: 47120,
        upMs: 2 * 60 * 60 * 1000,
        worktreePath: wtPath,
        sessionId: feature.id,
        health: {'kind': 'http-error', 'status': 404, 'probedAt': now - 9000},
        openUrl: 'http://127.0.0.1:9787',
      ),
      port(
        number: 5432,
        key: '901:0.0.0.0:5432',
        command: '/Applications/Docker.app/Contents/MacOS/com.docker.backend',
        address: '0.0.0.0',
        reach: 'exposed',
        pid: 901,
        upMs: 3 * 60 * 60 * 1000,
        docker: {
          'container': 'chat-ui-db-1',
          'compose': '${feature.projectPath}/compose.yml',
        },
      ),
      port(
        number: 5180,
        key: '51002:127.0.0.1:5180',
        command: 'node vite --port 5180',
        pid: 51002,
        upMs: 48 * 60 * 60 * 1000,
        health: {'kind': 'ok', 'status': 200, 'probedAt': now - 5000},
        openUrl: 'http://127.0.0.1:5180',
        orphan: {
          'formerBranch': 'feat/desktop-tabs',
          'formerWorktreePath': '${feature.projectPath}/.wt/feat/desktop-tabs',
          'removedAt': now - 2 * 24 * 60 * 60 * 1000,
        },
      ),
      port(
        number: 5181,
        key: '51044:127.0.0.1:5181',
        command: 'node storybook dev -p 5181',
        pid: 51044,
        upMs: 48 * 60 * 60 * 1000,
        health: {'kind': 'ok', 'status': 200, 'probedAt': now - 5000},
        openUrl: 'http://127.0.0.1:5181',
        orphan: {
          'formerBranch': 'feat/desktop-tabs',
          'formerWorktreePath': '${feature.projectPath}/.wt/feat/desktop-tabs',
        },
      ),
    ];

    _emit(
      Envelope(
        t: MsgType.event,
        id: Ulid().toString(),
        body: {
          'kind': 'ports.snapshot',
          'snapshot': {
            'ports': [
              for (final p in all)
                if (!_killedPorts.contains(p['port'] as int)) p,
            ],
            'scannedAt': now,
            'scanOk': true,
          },
        },
      ),
    );
  }

  void _replaySession(String sessionId) {
    final s = _sessions[sessionId];
    if (s == null) return;
    for (final e in s.events) {
      _emit(
        Envelope(
          t: MsgType.event,
          id: Ulid().toString(),
          body: {'kind': 'session.event', 'event': e.toJson()},
        ),
      );
    }
  }

  void _handleCmd(Envelope env) {
    final kind = env.body['kind'] as String? ?? '';

    // Commands that don't target an existing session.
    switch (kind) {
      case 'session.spawn':
        _spawnPending(env);
        return;
      case 'project.browse':
        _browse(env);
        return;
      case 'project.add':
        _addProject(env);
        return;
      case 'repo.refresh':
        _emit(Envelope(t: MsgType.ack, id: env.id));
        _pushRepos();
        return;
      case 'metrics.watch':
        _emit(Envelope(t: MsgType.ack, id: env.id));
        if (env.body['on'] == true) {
          _startMetrics();
        } else {
          _stopMetrics();
        }
        return;
      case 'ports.watch':
        _emit(Envelope(t: MsgType.ack, id: env.id));
        // Mirror the real server: on watch-on, paint from a plausible snapshot
        // immediately (SPEC-41). A no-op on watch-off — no ambient polling.
        if (env.body['on'] == true) _pushPorts();
        return;
      // SPEC-43/44: the demo answers the destructive and capability commands so
      // the confirms lead somewhere. Deliberately shallow — it reports the happy
      // outcome and re-pushes the snapshot; the refusal table is the real
      // server's job and is covered by its own tests.
      case 'ports.kill':
        final killedPort = env.body['port'];
        if (killedPort is int) _killedPorts.add(killedPort);
        _emit(
          Envelope(
            t: MsgType.ack,
            id: env.id,
            body: {
              'outcome': 'released',
              'address': env.body['address'],
              'port': killedPort,
            },
          ),
        );
        _pushPorts();
        return;
      case 'ports.killOrphans':
        // The two seeded orphans (see `_pushPorts`).
        const orphanPorts = [5180, 5181];
        _killedPorts.addAll(orphanPorts);
        _emit(
          Envelope(
            t: MsgType.ack,
            id: env.id,
            body: {
              'results': [
                for (final p in orphanPorts)
                  {'outcome': 'released', 'address': '127.0.0.1', 'port': p},
              ],
            },
          ),
        );
        _pushPorts();
        return;
      case 'ports.watchPort':
        final watchedPort = env.body['port'];
        if (watchedPort is int) {
          if (env.body['on'] == true) {
            _watchedPorts.add(watchedPort);
          } else {
            _watchedPorts.remove(watchedPort);
          }
        }
        _emit(Envelope(t: MsgType.ack, id: env.id));
        _pushPorts();
        return;
      case 'ports.forward':
        final forwarded = env.body['port'];
        // One id, used in both fields: the real route addresses a grant BY its
        // id, so a fixed `path` would contradict the `grantId` beside it.
        final grantId = 'demo-grant-${Ulid()}';
        _emit(
          Envelope(
            t: MsgType.ack,
            id: env.id,
            body: {
              'grant': {
                'grantId': grantId,
                'port': forwarded,
                'path': '/forward/$grantId/',
                'createdAt': DateTime.now().millisecondsSinceEpoch,
                'expiresAt':
                    DateTime.now().millisecondsSinceEpoch + 30 * 60 * 1000,
                'browser': env.body['browser'] == true,
              },
            },
          ),
        );
        return;
      case 'ports.forward.stop':
        _emit(Envelope(t: MsgType.ack, id: env.id));
        return;
      case 'session.close':
      case 'session.reopen':
        {
          // Mirror the real server: flip the flag, then re-broadcast, so the
          // sidebar/board drop or restore the row exactly as they would live.
          final id = env.body['sessionId'] as String?;
          final target = id == null ? null : _sessions[id];
          if (target != null) target.closed = kind == 'session.close';
          _emit(Envelope(t: MsgType.ack, id: env.id));
          _pushSessions();
          _pushRepos();
          return;
        }
      case 'session.listClosed':
        _emit(
          Envelope(
            t: MsgType.ack,
            id: env.id,
            body: {
              'sessions': [
                // Sessions closed during this run, plus the static fixtures that
                // give the demo something to look at on a cold start.
                for (final c in _sessions.values.where((c) => c.closed))
                  {
                    'id': c.id,
                    'projectId': c.projectId,
                    'agent': c.agent,
                    'title': c.title,
                    'status': 'exited',
                    'policy': 'ask-on-risky',
                    'lastActivityAt': DateTime.now().millisecondsSinceEpoch,
                    'lastPreview': c.preview,
                    if (c.branch != null) 'branch': c.branch,
                    'closed': true,
                    // The demo's repo list carries no worktree for this one, so
                    // the "worktree removed" chip has something to render.
                    if (c.id == 's-closed-2') 'orphaned': true,
                  },
              ],
            },
          ),
        );
        return;
      case 'agents.list':
        _emit(
          Envelope(
            t: MsgType.ack,
            id: env.id,
            body: const {
              'agents': [
                {
                  'id': 'pi',
                  'label': 'Pi (native)',
                  'transport': 'native',
                  'available': true,
                },
              ],
            },
          ),
        );
        return;
    }

    final sid = env.body['sessionId'] as String? ?? '';
    final session = _sessions[sid];
    if (session == null) {
      _emit(
        Envelope(
          t: MsgType.err,
          id: env.id,
          body: {'message': 'no such session'},
        ),
      );
      return;
    }

    switch (kind) {
      case 'send.message':
        final text = env.body['text'] as String? ?? '';
        // A pending draft materialises its worktree/branch on first message.
        if (session.pending) {
          session.pending = false;
          session.branch = _slugify(text);
          session.title = text.length > 40 ? text.substring(0, 40) : text;
          _pushSessions();
          _pushRepos();
        }
        _appendEvent(session, EventKind.userMessage, {'text': text});
        _emit(Envelope(t: MsgType.ack, id: env.id));
        _scriptAgentReply(session, text);
      default:
        _emit(Envelope(t: MsgType.ack, id: env.id));
    }
  }

  void _spawnPending(Envelope env) {
    final pid = env.body['projectId'] as String? ?? '';
    final agent = env.body['agent'] as String? ?? 'pi';
    final template = _sessions.values.firstWhere(
      (s) => s.projectId == pid,
      orElse: () => _sessions.values.first,
    );
    final id = 's-draft-${DateTime.now().microsecondsSinceEpoch}';
    _sessions[id] = _FakeSession(
      id: id,
      projectId: pid,
      projectName: template.projectName,
      projectPath: template.projectPath,
      agent: agent,
      title: '',
      preview: '',
      pending: true,
    );
    _emit(Envelope(t: MsgType.ack, id: env.id, body: {'sessionId': id}));
    _pushSessions();
    _pushRepos();
  }

  void _browse(Envelope env) {
    final path = env.body['path'] as String? ?? '/Users/demo';
    _emit(
      Envelope(
        t: MsgType.ack,
        id: env.id,
        body: {
          'path': path,
          'parent': path == '/'
              ? null
              : path.replaceAll(RegExp(r'/[^/]+$'), ''),
          'entries': [
            {'name': 'makit', 'path': '$path/makit', 'isRepo': true},
            {'name': 'notes', 'path': '$path/notes', 'isRepo': false},
          ],
        },
      ),
    );
  }

  void _addProject(Envelope env) {
    final path = env.body['path'] as String? ?? '';
    if (path.isEmpty) {
      _emit(
        Envelope(
          t: MsgType.err,
          id: env.id,
          body: {'message': 'project.add requires a string `path`'},
        ),
      );
      return;
    }
    final id = 'proj-added-${_addedProjects.length + 1}';
    _addedProjects[id] = path;
    _emit(Envelope(t: MsgType.ack, id: env.id, body: {'projectId': id}));
    _pushProjects();
    _pushRepos();
  }

  String _slugify(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s-]'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .take(6)
      .join('-');

  void _scriptAgentReply(_FakeSession s, String userText) {
    Timer(const Duration(milliseconds: 400), () {
      _appendEvent(s, EventKind.agentMessage, {
        'text': "Got it — I'll handle that. (echo: $userText)",
      });
    });
  }

  void _appendEvent(
    _FakeSession s,
    EventKind kind,
    Map<String, dynamic> payload,
  ) {
    final ev = SessionEvent(
      seq: s.events.length + 1,
      sessionId: s.id,
      ts: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
      payload: payload,
    );
    s.events.add(ev);
    _emit(
      Envelope(
        t: MsgType.event,
        id: Ulid().toString(),
        body: {'kind': 'session.event', 'event': ev.toJson()},
      ),
    );
  }

  void _emit(Envelope env) {
    if (!_outCtrl.isClosed) _outCtrl.add(env);
  }

  // ---- scripted transcripts -----------------------------------------------

  List<SessionEvent> _scriptCodex(String sid) {
    int seq = 0;
    int ts = DateTime.now().millisecondsSinceEpoch - 60000;
    SessionEvent ev(EventKind k, Map<String, dynamic> p) => SessionEvent(
      seq: ++seq,
      sessionId: sid,
      ts: ts += 1000,
      kind: k,
      payload: p,
    );
    return [
      ev(EventKind.userMessage, {
        'text': 'Wire up the pairing screen with mDNS discovery.',
      }),
      ev(EventKind.agentMessage, {
        'text':
            'I will inspect the current pairing module, then add an mDNS browse list.',
      }),
      ev(EventKind.toolCallStart, {
        'callId': 'c1',
        'name': 'read',
        'args': {'path': 'app/lib/pairing/pairing_screen.dart'},
        'risk': 'safe',
      }),
      ev(EventKind.toolCallEnd, {
        'callId': 'c1',
        'exitCode': 0,
        'summary': '74 lines read',
      }),
      ev(EventKind.toolCallStart, {
        'callId': 'c2',
        'name': 'edit',
        'args': {
          'path': 'app/lib/pairing/pairing_screen.dart',
          'oldText':
              'Widget build(BuildContext context) {\n  return const Text(\'Scan a QR to pair\');\n}',
          'newText':
              'Widget build(BuildContext context) {\n  return Column(\n    children: const [\n      Text(\'Scan a QR to pair\'),\n      MdnsServerList(),\n    ],\n  );\n}',
        },
        'risk': 'risky',
      }),
      ev(EventKind.toolCallDelta, {'callId': 'c2', 'chunk': '+12 −3\n'}),
      ev(EventKind.toolCallEnd, {
        'callId': 'c2',
        'exitCode': 0,
        'summary': 'edit src/foo.dart · +12 −3',
      }),
      ev(EventKind.agentMessage, {'text': 'Done. Ready for the next step.'}),
      ev(EventKind.sessionStatus, {'status': 'awaiting-input'}),
    ];
  }

  List<SessionEvent> _scriptPi(String sid) {
    int seq = 0;
    int ts = DateTime.now().millisecondsSinceEpoch - 120000;
    SessionEvent ev(EventKind k, Map<String, dynamic> p) => SessionEvent(
      seq: ++seq,
      sessionId: sid,
      ts: ts += 1500,
      kind: k,
      payload: p,
    );
    return [
      ev(EventKind.userMessage, {
        'text': 'Review docs/ARCHITECTURE.md for inconsistencies.',
      }),
      ev(EventKind.agentMessage, {
        'text':
            '3 notes:\n1. Wire protocol claims JSON but mentions Noise-IK — clarify those are different layers.\n2. SQLite vs SQLCipher decision is deferred but mentioned in §11.\n3. Mobile uses Riverpod — pin a state-shape convention.',
      }),
      ev(EventKind.sessionStatus, {'status': 'idle'}),
    ];
  }

  List<SessionEvent> _scriptClaude(String sid) {
    int seq = 0;
    int ts = DateTime.now().millisecondsSinceEpoch - 30000;
    SessionEvent ev(EventKind k, Map<String, dynamic> p) => SessionEvent(
      seq: ++seq,
      sessionId: sid,
      ts: ts += 1200,
      kind: k,
      payload: p,
    );
    return [
      ev(EventKind.userMessage, {
        'text': 'Fix the tab drag-and-drop regression on macOS 15.',
      }),
      ev(EventKind.agentMessage, {
        'text': 'Suspect Sources/Tabs/TabBar.swift — patching now.',
      }),
      ev(EventKind.toolCallStart, {
        'callId': 'c-edit',
        'name': 'edit',
        'args': {
          'path': 'Sources/Tabs/TabBar.swift',
          'oldText': 'let dragThreshold = 4.0',
          'newText': 'let dragThreshold = 8.0',
        },
        'risk': 'risky',
      }),
    ];
  }
}

class _FakeSession {
  _FakeSession({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.projectPath,
    required this.agent,
    required this.title,
    required this.preview,
    this.status = 'idle',
    this.branch,
    this.pending = false,
  });
  final String id;
  final String projectId;
  final String projectName;
  final String projectPath;
  final String agent;
  String title;
  String preview;
  String status;

  /// Feature-branch worktree this session runs in; null = primary checkout.
  String? branch;
  bool pending;

  /// Closed (SPEC-29): the agent was released. Excluded from the active
  /// snapshot, reported by `session.listClosed`, restored by `session.reopen`.
  /// Always starts live — the demo's cold-start closed rows are static fixtures.
  bool closed = false;
  final List<SessionEvent> events = [];
}

extension on SessionEvent {
  Map<String, dynamic> toJson() => {
    'seq': seq,
    'sessionId': sessionId,
    'ts': ts,
    'kind': kind.wire,
    'payload': payload,
  };
}

// Silence unused-import warning for jsonEncode if removed later.
// ignore: unused_element
void _keepImport() => jsonEncode('');
