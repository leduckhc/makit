/// Domain model used by the UI. Decoupled from wire types so we can evolve
/// either side independently.
library;

import '../transport/protocol.dart';

/// One command exposed by the agent — extension, prompt template, or skill.
class SlashCmd {
  const SlashCmd({
    required this.name,
    required this.description,
    required this.source,
    this.location,
  });

  /// Without the leading `/`. e.g. `skill:foo`, `fix-tests`, `session-name`.
  final String name;
  final String description;
  /// `extension` | `prompt` | `skill`
  final String source;
  /// `user` | `project` | `path` — optional.
  final String? location;

  String get invocation => '/$name';

  static SlashCmd? fromJson(Map<String, dynamic> j) {
    final name = j['name'] as String?;
    if (name == null) return null;
    return SlashCmd(
      name: name,
      description: (j['description'] as String?) ?? '',
      source: (j['source'] as String?) ?? 'extension',
      location: j['location'] as String?,
    );
  }
}

class Project {
  Project({
    required this.id,
    required this.name,
    required this.path,
    this.pinned = false,
    this.lastActivityAt = 0,
  });

  final String id;
  final String name;
  final String path;
  final bool pinned;
  final int lastActivityAt;
}

enum SessionStatus { idle, running, awaitingInput, awaitingApproval, error, exited }

SessionStatus parseStatus(String s) => switch (s) {
      'idle' => SessionStatus.idle,
      'running' => SessionStatus.running,
      'awaiting-input' => SessionStatus.awaitingInput,
      'awaiting-approval' => SessionStatus.awaitingApproval,
      'error' => SessionStatus.error,
      'exited' => SessionStatus.exited,
      _ => SessionStatus.idle,
    };

enum ApprovalPolicy { yolo, askOnRisky, askAlways }

ApprovalPolicy parsePolicy(String s) => switch (s) {
      'yolo' => ApprovalPolicy.yolo,
      'ask-on-risky' => ApprovalPolicy.askOnRisky,
      'ask-always' => ApprovalPolicy.askAlways,
      _ => ApprovalPolicy.askOnRisky,
    };

class Session {
  Session({
    required this.id,
    required this.projectId,
    required this.agent,
    required this.title,
    required this.status,
    required this.policy,
    this.lastActivityAt = 0,
    this.lastPreview = '',
  });

  final String id;
  final String projectId;
  final String agent;
  final String title;
  final SessionStatus status;
  final ApprovalPolicy policy;
  final int lastActivityAt;
  final String lastPreview;

  Session copyWith({
    SessionStatus? status,
    ApprovalPolicy? policy,
    String? title,
    int? lastActivityAt,
    String? lastPreview,
  }) =>
      Session(
        id: id,
        projectId: projectId,
        agent: agent,
        title: title ?? this.title,
        status: status ?? this.status,
        policy: policy ?? this.policy,
        lastActivityAt: lastActivityAt ?? this.lastActivityAt,
        lastPreview: lastPreview ?? this.lastPreview,
      );
}

/// A folded view of the event stream — what the chat list actually renders.
sealed class ChatItem {
  ChatItem({required this.seq, required this.ts});
  final int seq;
  final int ts;
}

class UserMessageItem extends ChatItem {
  UserMessageItem({required super.seq, required super.ts, required this.text});
  final String text;
}

class AgentMessageItem extends ChatItem {
  AgentMessageItem({required super.seq, required super.ts, required this.text});
  final String text;
}

class ToolCallItem extends ChatItem {
  ToolCallItem({
    required super.seq,
    required super.ts,
    required this.callId,
    required this.name,
    required this.args,
    this.deltas = const [],
    this.ended = false,
    this.exitCode,
    this.summary,
    this.risk = 'safe',
  });

  final String callId;
  final String name;
  final Map<String, dynamic> args;
  final List<String> deltas;
  final bool ended;
  final int? exitCode;
  final String? summary;
  final String risk;

  ToolCallItem copyWith({
    List<String>? deltas,
    bool? ended,
    int? exitCode,
    String? summary,
  }) =>
      ToolCallItem(
        seq: seq,
        ts: ts,
        callId: callId,
        name: name,
        args: args,
        risk: risk,
        deltas: deltas ?? this.deltas,
        ended: ended ?? this.ended,
        exitCode: exitCode ?? this.exitCode,
        summary: summary ?? this.summary,
      );
}

class ApprovalRequestItem extends ChatItem {
  ApprovalRequestItem({
    required super.seq,
    required super.ts,
    required this.callId,
    required this.tool,
    required this.preview,
    this.decided = false,
    this.decision,
  });

  final String callId;
  final String tool;
  final String preview;
  final bool decided;
  final String? decision; // 'approve' | 'deny'
}

class ErrorItem extends ChatItem {
  ErrorItem({required super.seq, required super.ts, required this.message});
  final String message;
}

/// Fold a raw [SessionEvent] stream into ordered [ChatItem]s. Tool-call deltas
/// are merged into the matching [ToolCallItem] so the UI sees one card per call.
List<ChatItem> foldEvents(Iterable<SessionEvent> events) {
  final items = <ChatItem>[];
  final byCall = <String, int>{}; // callId -> index in items

  for (final e in events) {
    switch (e.kind) {
      case EventKind.userMessage:
        items.add(UserMessageItem(seq: e.seq, ts: e.ts, text: e.payload['text'] as String? ?? ''));
      case EventKind.agentMessage:
        items.add(AgentMessageItem(seq: e.seq, ts: e.ts, text: e.payload['text'] as String? ?? ''));
      case EventKind.agentThinking:
        // M0: ignore reasoning trace; could render as a faint card later.
        break;
      case EventKind.toolCallStart:
        final callId = e.payload['callId'] as String;
        final item = ToolCallItem(
          seq: e.seq,
          ts: e.ts,
          callId: callId,
          name: e.payload['name'] as String? ?? 'tool',
          args: Map<String, dynamic>.from(e.payload['args'] as Map? ?? const {}),
          risk: e.payload['risk'] as String? ?? 'safe',
        );
        byCall[callId] = items.length;
        items.add(item);
      case EventKind.toolCallDelta:
        final callId = e.payload['callId'] as String;
        final idx = byCall[callId];
        if (idx != null && items[idx] is ToolCallItem) {
          final cur = items[idx] as ToolCallItem;
          items[idx] = cur.copyWith(deltas: [...cur.deltas, e.payload['chunk'] as String? ?? '']);
        }
      case EventKind.toolCallEnd:
        final callId = e.payload['callId'] as String;
        final idx = byCall[callId];
        if (idx != null && items[idx] is ToolCallItem) {
          final cur = items[idx] as ToolCallItem;
          items[idx] = cur.copyWith(
            ended: true,
            exitCode: (e.payload['exitCode'] as num?)?.toInt(),
            summary: e.payload['summary'] as String?,
          );
        }
      case EventKind.approvalRequest:
        items.add(ApprovalRequestItem(
          seq: e.seq,
          ts: e.ts,
          callId: e.payload['callId'] as String,
          tool: e.payload['tool'] as String? ?? 'tool',
          preview: e.payload['preview'] as String? ?? '',
        ),);
      case EventKind.approvalDecision:
        // Mark the most recent matching approval request as decided.
        final callId = e.payload['callId'] as String;
        for (var i = items.length - 1; i >= 0; i--) {
          final item = items[i];
          if (item is ApprovalRequestItem && item.callId == callId && !item.decided) {
            items[i] = ApprovalRequestItem(
              seq: item.seq,
              ts: item.ts,
              callId: item.callId,
              tool: item.tool,
              preview: item.preview,
              decided: true,
              decision: e.payload['decision'] as String?,
            );
            break;
          }
        }
      case EventKind.sessionStatus:
        // Handled at session level, not as chat item.
        break;
      case EventKind.sessionError:
        items.add(ErrorItem(seq: e.seq, ts: e.ts, message: e.payload['message'] as String? ?? 'error'));
      case EventKind.sessionCommands:
        // Handled by store, not as a chat item.
        break;
    }
  }
  return items;
}
