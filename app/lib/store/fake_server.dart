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

  void start() {
    _seed();
    // Push initial state shortly after connect so UI has something to show.
    _seedTimer = Timer(const Duration(milliseconds: 150), _pushInitialState);
  }

  void stop() {
    _seedTimer?.cancel();
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
  }

  void _pushInitialState() {
    _pushProjects();
    _pushRepos();
    _pushSessions();
  }

  void _pushProjects() {
    final projects = <String, Map<String, dynamic>>{};
    for (final s in _sessions.values) {
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
  /// a feature-branch worktree carrying diff stats / an open PR.
  void _pushRepos() {
    final byProject = <String, List<_FakeSession>>{};
    for (final s in _sessions.values) {
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
          if (i == 1)
            'pr': {
              'number': 41 + i,
              'url': 'https://github.com/demo/pull/${41 + i}',
              'state': 'OPEN',
              'title': branch,
              'isDraft': false,
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
        'worktrees': worktrees,
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

  void _pushSessions() {
    _emit(
      Envelope(
        t: MsgType.event,
        id: Ulid().toString(),
        body: {
          'kind': 'sessions.snapshot',
          'sessions': _sessions.values
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
                },
              )
              .toList(),
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
