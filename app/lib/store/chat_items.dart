/// Chat item tree + event folding — the folded view of the session event
/// stream that the chat list actually renders. Extracted from `models.dart`
/// (SPEC-19), pairs with SPEC-16 S4.
library;

import '../transport/protocol.dart';

/// How dangerous a tool call is, as classified by the agent. Parsed at the
/// model boundary (unknown/missing → [ToolRisk.safe]) so the UI switches on a
/// closed set instead of raw `'safe'`/`'risky'`/`'destructive'` strings.
enum ToolRisk { safe, risky, destructive }

ToolRisk parseToolRisk(String? s) => switch (s) {
  'risky' => ToolRisk.risky,
  'destructive' => ToolRisk.destructive,
  _ => ToolRisk.safe,
};

/// A tool call's lifecycle state, derived from [ToolCallItem.ended] and its
/// exit code so the UI has a single tri-state to switch on.
enum ToolStatus { running, ok, failed }

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
  AgentMessageItem({
    required super.seq,
    required super.ts,
    required this.text,
    this.msgId,
    this.streaming = false,
  });
  final String text;

  /// Stable id tying a streamed message's deltas together. Null for
  /// non-streamed messages (stub echoes, backfilled transcript).
  final String? msgId;

  /// True while deltas are still arriving; false once the final message lands.
  final bool streaming;

  AgentMessageItem copyWith({String? text, bool? streaming}) =>
      AgentMessageItem(
        seq: seq,
        ts: ts,
        text: text ?? this.text,
        msgId: msgId,
        streaming: streaming ?? this.streaming,
      );
}

/// An image or GIF the agent produced (a tool result, or a local file it
/// referenced) — SPEC-22. Carries only the descriptor: the bytes are fetched
/// lazily from the server's `/media/<mediaId>` route, so replaying a long
/// transcript costs nothing until a row scrolls into view.
class AgentMediaItem extends ChatItem {
  AgentMediaItem({
    required super.seq,
    required super.ts,
    required this.mediaId,
    required this.mime,
    this.sizeBytes = 0,
    this.alt,
    this.callId,
  });

  /// sha256 of the bytes — both the fetch path and the cache key.
  final String mediaId;
  final String mime;
  final int sizeBytes;

  /// Description/filename for a11y and the failure placeholder.
  final String? alt;

  /// The tool call this came out of, when it came from one.
  final String? callId;
}

class ThinkingItem extends ChatItem {
  ThinkingItem({
    required super.seq,
    required super.ts,
    required this.text,
    this.thinkId,
    this.streaming = false,
  });
  final String text;

  /// Streamed thinking id (ties deltas to the final `agent.thinking`). Null for
  /// non-streamed thinking (e.g. backfilled history or the stub adapter).
  final String? thinkId;

  /// True while reasoning tokens are still streaming in.
  final bool streaming;

  ThinkingItem copyWith({String? text, bool? streaming}) => ThinkingItem(
    seq: seq,
    ts: ts,
    text: text ?? this.text,
    thinkId: thinkId,
    streaming: streaming ?? this.streaming,
  );
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
    this.output,
    this.details,
    this.risk = ToolRisk.safe,
  });

  final String callId;
  final String name;
  final Map<String, dynamic> args;
  final List<String> deltas;
  final bool ended;
  final int? exitCode;
  final String? summary;

  /// Full tool result text (file contents, bash stdout, error message). Shown
  final String? output;

  /// Structured tool result (e.g. askUserQuestion's {indices, answers}) for
  /// renderers that want more than the text. Null for most tools.
  final Map<String, dynamic>? details;
  final ToolRisk risk;

  /// The tool result text: streamed [deltas] when present, else the final
  /// [output] (empty string when neither is set). The single source of this
  /// idiom, which was previously copy-pasted with inconsistent precedence.
  String get resultText => deltas.isNotEmpty ? deltas.join() : (output ?? '');

  /// Lifecycle state derived from [ended] and [exitCode].
  ToolStatus get status => !ended
      ? ToolStatus.running
      : (exitCode ?? 0) != 0
      ? ToolStatus.failed
      : ToolStatus.ok;

  ToolCallItem copyWith({
    List<String>? deltas,
    bool? ended,
    int? exitCode,
    String? summary,
    String? output,
    Map<String, dynamic>? details,
  }) => ToolCallItem(
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
    output: output ?? this.output,
    details: details ?? this.details,
  );
}

class ErrorItem extends ChatItem {
  ErrorItem({required super.seq, required super.ts, required this.message});
  final String message;
}

/// Find the in-progress [ChatItem] registered under [id] in [index] and update
/// it via [append]; otherwise build a fresh one via [create] and (when
/// [register] is set) record its position so later deltas find it. [create]
/// may return null to add nothing — used by tool deltas (which must not create
/// a card without a preceding start) and the empty-final thinking guard.
void _upsertStream<T extends ChatItem>(
  List<ChatItem> items,
  Map<String, int> index,
  String? id,
  T? Function() create,
  T Function(T current) append, {
  bool register = true,
}) {
  final idx = id != null ? index[id] : null;
  if (idx != null && items[idx] is T) {
    items[idx] = append(items[idx] as T);
    return;
  }
  final created = create();
  if (created == null) return;
  if (register && id != null) index[id] = items.length;
  items.add(created);
}

/// Fold a raw [SessionEvent] stream into ordered [ChatItem]s. Tool-call deltas
/// are merged into the matching [ToolCallItem] so the UI sees one card per call.
List<ChatItem> foldEvents(Iterable<SessionEvent> events) {
  final items = <ChatItem>[];
  final byCall = <String, int>{}; // callId -> index in items
  final byMsg = <String, int>{}; // streamed msgId -> index in items
  final byThink = <String, int>{}; // streamed thinkId -> index in items

  for (final e in events) {
    switch (e.kind) {
      case EventKind.userMessage:
        items.add(
          UserMessageItem(
            seq: e.seq,
            ts: e.ts,
            text: e.payload['text'] as String? ?? '',
          ),
        );
      case EventKind.agentMessage:
        // Final (authoritative) message. Finalizes the streamed msgId's bubble
        // in place, or appends a fresh (non-streamed) bubble when there is none.
        final msgId = e.payload['msgId'] as String?;
        final text = e.payload['text'] as String? ?? '';
        _upsertStream<AgentMessageItem>(
          items,
          byMsg,
          msgId,
          () => AgentMessageItem(seq: e.seq, ts: e.ts, text: text),
          (cur) => cur.copyWith(text: text, streaming: false),
          register: false,
        );
      case EventKind.agentMessageDelta:
        // Streaming token. Append to the bubble for this msgId, creating it on
        // the first delta.
        final msgId = e.payload['msgId'] as String? ?? '';
        final chunk = e.payload['chunk'] as String? ?? '';
        _upsertStream<AgentMessageItem>(
          items,
          byMsg,
          msgId,
          () => AgentMessageItem(
            seq: e.seq,
            ts: e.ts,
            text: chunk,
            msgId: msgId,
            streaming: true,
          ),
          (cur) => cur.copyWith(text: cur.text + chunk),
        );
      case EventKind.agentMedia:
        // Defensive: a descriptor with no fetchable id would render a permanent
        // broken placeholder, so drop it instead.
        final mediaId = e.payload['mediaId'];
        if (mediaId is String && mediaId.isNotEmpty) {
          items.add(
            AgentMediaItem(
              seq: e.seq,
              ts: e.ts,
              mediaId: mediaId,
              mime: e.payload['mime'] as String? ?? 'image/png',
              sizeBytes: (e.payload['sizeBytes'] as num?)?.toInt() ?? 0,
              alt: e.payload['alt'] as String?,
              callId: e.payload['callId'] as String?,
            ),
          );
        }
      case EventKind.agentThinkingDelta:
        // Streaming reasoning token. Append to the card for this thinkId,
        // creating it on the first delta so it is anchored at the point
        // reasoning STARTED (before the answer), matching the terminal.
        final thinkId = e.payload['thinkId'] as String? ?? '';
        final chunk = e.payload['chunk'] as String? ?? '';
        _upsertStream<ThinkingItem>(
          items,
          byThink,
          thinkId,
          () => ThinkingItem(
            seq: e.seq,
            ts: e.ts,
            text: chunk,
            thinkId: thinkId,
            streaming: true,
          ),
          (cur) => cur.copyWith(text: cur.text + chunk),
        );
      case EventKind.agentThinking:
        // Final (authoritative) thinking. Finalizes the streamed thinkId's card
        // in place, or appends a fresh card — but only when non-empty (the
        // empty-final guard skips blank standalone thinking).
        final thinkId = e.payload['thinkId'] as String?;
        final text = e.payload['text'] as String? ?? '';
        _upsertStream<ThinkingItem>(
          items,
          byThink,
          thinkId,
          () => text.trim().isNotEmpty
              ? ThinkingItem(seq: e.seq, ts: e.ts, text: text)
              : null,
          (cur) => cur.copyWith(text: text, streaming: false),
          register: false,
        );
      case EventKind.toolCallStart:
        final callId = e.payload['callId'] as String;
        final item = ToolCallItem(
          seq: e.seq,
          ts: e.ts,
          callId: callId,
          name: e.payload['name'] as String? ?? 'tool',
          args: Map<String, dynamic>.from(
            e.payload['args'] as Map? ?? const {},
          ),
          risk: parseToolRisk(e.payload['risk'] as String?),
        );
        byCall[callId] = items.length;
        items.add(item);
      case EventKind.toolCallDelta:
        final callId = e.payload['callId'] as String;
        _upsertStream<ToolCallItem>(
          items,
          byCall,
          callId,
          () => null, // A delta without a preceding start creates nothing.
          (cur) => cur.copyWith(
            deltas: [...cur.deltas, e.payload['chunk'] as String? ?? ''],
          ),
        );
      case EventKind.toolCallEnd:
        final callId = e.payload['callId'] as String;
        final idx = byCall[callId];
        if (idx != null && items[idx] is ToolCallItem) {
          final cur = items[idx] as ToolCallItem;
          items[idx] = cur.copyWith(
            ended: true,
            exitCode: (e.payload['exitCode'] as num?)?.toInt(),
            summary: e.payload['summary'] as String?,
            output: e.payload['output'] as String?,
            details: (e.payload['details'] as Map?)?.cast<String, dynamic>(),
          );
        }
      case EventKind.sessionStatus:
        // Handled at session level, not as chat item.
        break;
      case EventKind.sessionError:
        items.add(
          ErrorItem(
            seq: e.seq,
            ts: e.ts,
            message: e.payload['message'] as String? ?? 'error',
          ),
        );
      case EventKind.sessionCommands:
        // Handled by store, not as a chat item.
        break;
      case EventKind.sessionMeta:
        // Model/thinking snapshot — handled by store, not a chat item.
        break;
      case EventKind.sessionActionError:
        // Action error — handled by store, surfaces as a snackbar, not a chat item.
        break;
    }
  }
  return items;
}
