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
    )..events.addAll(_scriptClaude('s-claude-1'));
  }

  void _pushInitialState() {
    // Push projects.
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

    // Push session list summaries.
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
        _appendEvent(session, EventKind.userMessage, {'text': text});
        _emit(Envelope(t: MsgType.ack, id: env.id));
        _scriptAgentReply(session, text);
      default:
        _emit(Envelope(t: MsgType.ack, id: env.id));
    }
  }

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
  });
  final String id;
  final String projectId;
  final String projectName;
  final String projectPath;
  final String agent;
  final String title;
  final String preview;
  String status;
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
