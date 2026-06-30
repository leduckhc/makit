/// Wire protocol — JSON envelopes shared with the server.
///
/// Hand-written (no codegen) for M0 so the project builds without a
/// `build_runner` pass. We'll switch to `freezed` + `json_serializable` once
/// the protocol stabilizes and we want stronger guarantees on both ends.
library;

import 'dart:convert';

const protocolVersion = 1;

/// All message types on the wire.
enum MsgType {
  hello,
  helloAck,
  sub,
  unsub,
  event,
  cmd,
  ack,
  err,
  presence,
  ping,
  pong,
  srvRequest,
  srvResponse;

  String get wire => switch (this) {
    MsgType.hello => 'hello',
    MsgType.helloAck => 'hello.ack',
    MsgType.sub => 'sub',
    MsgType.unsub => 'unsub',
    MsgType.event => 'event',
    MsgType.cmd => 'cmd',
    MsgType.ack => 'ack',
    MsgType.err => 'err',
    MsgType.presence => 'presence',
    MsgType.ping => 'ping',
    MsgType.pong => 'pong',
    MsgType.srvRequest => 'srv.request',
    MsgType.srvResponse => 'srv.response',
  };

  static MsgType? fromWire(String s) {
    for (final v in MsgType.values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// Envelope: every WS frame is one of these as JSON.
class Envelope {
  Envelope({
    required this.t,
    required this.id,
    this.v = protocolVersion,
    this.body = const {},
  });

  final MsgType t;
  final String id;
  final int v;
  final Map<String, dynamic> body;

  Map<String, dynamic> toJson() => {'v': v, 't': t.wire, 'id': id, ...body};

  String encode() => jsonEncode(toJson());

  static Envelope? decode(String raw) {
    final m = jsonDecode(raw);
    if (m is! Map<String, dynamic>) return null;
    final t = MsgType.fromWire(m['t'] as String? ?? '');
    if (t == null) return null;
    return Envelope(
      t: t,
      id: m['id'] as String? ?? '',
      v: m['v'] as int? ?? protocolVersion,
      body: Map<String, dynamic>.from(m)
        ..removeWhere((k, _) => k == 'v' || k == 't' || k == 'id'),
    );
  }
}

// ---------------------------------------------------------------------------
// Event kinds — projected into chat UI.
// ---------------------------------------------------------------------------

enum EventKind {
  userMessage,
  agentMessage,
  agentThinking,
  toolCallStart,
  toolCallDelta,
  toolCallEnd,
  approvalRequest,
  approvalDecision,
  sessionStatus,
  sessionError,
  sessionCommands;

  String get wire => switch (this) {
    EventKind.userMessage => 'user.message',
    EventKind.agentMessage => 'agent.message',
    EventKind.agentThinking => 'agent.thinking',
    EventKind.toolCallStart => 'tool.call.start',
    EventKind.toolCallDelta => 'tool.call.delta',
    EventKind.toolCallEnd => 'tool.call.end',
    EventKind.approvalRequest => 'approval.request',
    EventKind.approvalDecision => 'approval.decision',
    EventKind.sessionStatus => 'session.status',
    EventKind.sessionError => 'session.error',
    EventKind.sessionCommands => 'session.commands',
  };

  static EventKind? fromWire(String s) {
    for (final v in EventKind.values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

class SessionEvent {
  SessionEvent({
    required this.seq,
    required this.sessionId,
    required this.ts,
    required this.kind,
    required this.payload,
  });

  final int seq;
  final String sessionId;
  final int ts;
  final EventKind kind;
  final Map<String, dynamic> payload;

  static SessionEvent? fromJson(Map<String, dynamic> j) {
    final kind = EventKind.fromWire(j['kind'] as String? ?? '');
    if (kind == null) return null;
    return SessionEvent(
      seq: (j['seq'] as num).toInt(),
      sessionId: j['sessionId'] as String,
      ts: (j['ts'] as num).toInt(),
      kind: kind,
      payload: Map<String, dynamic>.from(j['payload'] as Map? ?? const {}),
    );
  }
}

// ---------------------------------------------------------------------------
// Commands: phone → server intents.
// ---------------------------------------------------------------------------

enum CmdKind {
  sendMessage,
  approve,
  deny,
  cancel,
  spawnSession,
  killSession,
  setApprovalPolicy;

  String get wire => switch (this) {
    CmdKind.sendMessage => 'send.message',
    CmdKind.approve => 'approve',
    CmdKind.deny => 'deny',
    CmdKind.cancel => 'cancel',
    CmdKind.spawnSession => 'session.spawn',
    CmdKind.killSession => 'session.kill',
    CmdKind.setApprovalPolicy => 'session.policy',
  };
}
