/// Chat item tree + event folding — the folded view of the session event
/// stream that the chat list actually renders. Extracted from `models.dart`
/// (SPEC-decomposition-and-dedup), pairs with SPEC-app-chat-simplification S4.
library;

import '../transport/protocol.dart';

// `isMediaId` is a wire fact (see transport/protocol.dart); re-exported so the
// event fold's consumers keep reading it from the store layer they already use.
export '../transport/protocol.dart' show isMediaId;

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

/// A descriptor for one image the user attached (SPEC-user-attachments), as it arrives on the
/// `user.message` payload. Bytes are NOT here — they are fetched from
/// `GET /media/<mediaId>` — because this event is replayed in full on resume.
class MediaAttachmentRef {
  const MediaAttachmentRef({
    required this.mediaId,
    required this.mime,
    this.name,
  });

  final String mediaId;
  final String mime;

  /// The name the user's file had, for a11y and the failure placeholder.
  final String? name;

  /// The `send.message` form: **id + name only**. The bytes went up to
  /// `POST /media` first and the server resolves the id against its own store
  /// (SPEC-user-attachments §3.3), so sending `mime` would be a claim the server ignores.
  Map<String, Object?> toWire() => {
    'mediaId': mediaId,
    if (name != null) 'name': name,
  };

  /// The `user.message` payload form, for the optimistic bubble.
  ///
  /// Deliberately the same shape [tryParse] reads and the server's echo carries:
  /// the optimistic copy is the one that survives the seq-collision dedup, so a
  /// field missing here is missing from the rendered bubble forever.
  Map<String, Object?> toEchoWire() => {
    'mediaId': mediaId,
    'mime': mime,
    if (name != null) 'name': name,
  };

  /// Parse one wire entry, or null when it is not usable. Skipping a malformed
  /// entry beats rendering a thumbnail that can never load.
  static MediaAttachmentRef? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['mediaId'];
    if (id is! String || !isMediaId(id)) return null;
    final mime = raw['mime'];
    final name = raw['name'];
    return MediaAttachmentRef(
      mediaId: id,
      mime: mime is String && mime.isNotEmpty ? mime : 'image/png',
      name: name is String && name.isNotEmpty ? name : null,
    );
  }

  /// Parse the `attachments` array off a `user.message` payload. Absent (all
  /// pre-SPEC-user-attachments history) or malformed → empty.
  static List<MediaAttachmentRef> parseList(Object? raw) {
    if (raw is! List) return const [];
    return [for (final e in raw) ?tryParse(e)];
  }

  // Value equality: a descriptor is its three fields, and these live in lists
  // that widgets diff (and that tests compare wholesale).
  @override
  bool operator ==(Object other) =>
      other is MediaAttachmentRef &&
      other.mediaId == mediaId &&
      other.mime == mime &&
      other.name == name;

  @override
  int get hashCode => Object.hash(mediaId, mime, name);

  @override
  String toString() =>
      'MediaAttachmentRef($mediaId, $mime${name == null ? '' : ', $name'})';
}

class UserMessageItem extends ChatItem {
  UserMessageItem({
    required super.seq,
    required super.ts,
    required this.text,
    this.attachments = const [],
    this.steered = false,
  });
  final String text;

  /// Images sent with this message (SPEC-user-attachments). Empty for a text-only turn.
  final List<MediaAttachmentRef> attachments;

  /// True when this message was injected into the turn that was ALREADY running
  /// instead of starting a new one (SPEC-mid-turn-steering-and-queue). Only codex can do it; the bubble
  /// is captioned so the user can tell steering from queueing.
  final bool steered;
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
/// referenced) — SPEC-assistant-display-media. Carries only the descriptor: the bytes are fetched
/// lazily from the server's `/media/<mediaId>` route, so replaying a long
/// transcript costs nothing until a row scrolls into view.
class AgentMediaItem extends ChatItem {
  AgentMediaItem({
    required super.seq,
    required super.ts,
    required this.mediaId,
    required this.mime,
    this.alt,
    this.callId,
  });

  /// sha256 of the bytes — both the fetch path and the cache key.
  final String mediaId;
  final String mime;

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
    this.lastTs,
  });
  final String text;

  /// Streamed thinking id (ties deltas to the final `agent.thinking`). Null for
  /// non-streamed thinking (e.g. backfilled history or the stub adapter).
  final String? thinkId;

  /// True while reasoning tokens are still streaming in.
  final bool streaming;

  /// Timestamp of the last observed reasoning event — the final `agent.thinking`
  /// or, for a still-streaming card, the most recent `agent.thinking.delta`
  /// (SPEC-session-timings D1). Null when no terminal/delta event has landed. [ts] stays the
  /// start, so the reasoning span is `[ts, lastTs]`.
  final int? lastTs;

  ThinkingItem copyWith({String? text, bool? streaming, int? lastTs}) =>
      ThinkingItem(
        seq: seq,
        ts: ts,
        text: text ?? this.text,
        thinkId: thinkId,
        streaming: streaming ?? this.streaming,
        lastTs: lastTs ?? this.lastTs,
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
    this.endedTs,
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

  /// Timestamp of the `tool.call.end` that closed this call (SPEC-session-timings D1), or
  /// null when no terminal event was observed. Null is NOT "still running":
  /// codex can leave an aborted call with no end forever (D6a), so a live
  /// counter must freeze at its turn's close rather than trust this. [ts] stays
  /// the start, so the span is `[ts, endedTs]`.
  final int? endedTs;

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
    int? endedTs,
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
    endedTs: endedTs ?? this.endedTs,
  );
}

class ErrorItem extends ChatItem {
  ErrorItem({required super.seq, required super.ts, required this.message});
  final String message;
}

/// A closed turn's receipt row (SPEC-session-timings D9): a dim `2m 13s · 14 tools`, plus a
/// `… waiting on you` gate token when the turn was actually blocked. Projected
/// into the chat items from [deriveTurns] at the closing edge — NOT built inside
/// [foldEvents] (D18). [seq]/[ts] are the closing `idle`'s, so it orders after
/// the turn's last content row.
class TurnReceiptItem extends ChatItem {
  TurnReceiptItem({
    required super.seq,
    required super.ts,
    required this.wallMs,
    required this.gatedMs,
    required this.toolCount,
  });

  /// The turn's wall clock (headline figure).
  final int wallMs;

  /// Time the turn was blocked on the user; the gate token shows only when > 0.
  final int gatedMs;

  /// Tool calls in the turn (pluralised per D20).
  final int toolCount;
}

/// Find the in-progress [ChatItem] registered under [id] in [index] and update
/// it via [append]; otherwise build a fresh one via [create] and (when
/// [register] is set) record its position so later deltas find it. [create]
/// may return null to add nothing — used by tool deltas (which must not create
/// a card without a preceding start) and the empty-final thinking guard.
///
/// Returns the index it wrote, or null when it wrote nothing. The caller needs
/// that index to keep its per-row bookkeeping (see [ChatItemFold._noteMedia]).
int? _upsertStream<T extends ChatItem>(
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
    return idx;
  }
  final created = create();
  if (created == null) return null;
  if (register && id != null) index[id] = items.length;
  items.add(created);
  return items.length - 1;
}

/// Fold a raw [SessionEvent] stream into ordered [ChatItem]s. Tool-call deltas
/// are merged into the matching [ToolCallItem] so the UI sees one card per call.
///
/// A convenience wrapper over [ChatItemFold] for callers that hold the whole
/// stream. Live code uses the fold itself, and extends it — see
/// `SessionTranscript`.
List<ChatItem> foldEvents(Iterable<SessionEvent> events) =>
    (ChatItemFold()..addAll(events)).rows;

/// The fold of a session's events, kept so the next event costs one step
/// instead of one whole pass.
///
/// The fold used to run from the first event on every store update, which made
/// a streaming turn quadratic: `tool/perf/fold_bench.dart` measured 2.54 ms per
/// delta at 20000 prior events. [ChatItemFold] holds the rows and the three
/// stream indexes, so [add] is O(1) and only [rows] walks the list.
class ChatItemFold {
  ChatItemFold();

  /// A working copy. The source keeps its own rows, because the store hands the
  /// previous fold out as immutable state.
  ChatItemFold.from(ChatItemFold other)
    : _items = List<ChatItem>.of(other._items),
      _byCall = Map<String, int>.of(other._byCall),
      _byMsg = Map<String, int>.of(other._byMsg),
      _byThink = Map<String, int>.of(other._byThink),
      _mediaInRow = {
        for (final e in other._mediaInRow.entries)
          e.key: Set<String>.of(e.value),
      },
      _shownMedia = Map<String, int>.of(other._shownMedia);

  List<ChatItem> _items = <ChatItem>[];

  /// callId -> index in [_items].
  Map<String, int> _byCall = <String, int>{};

  /// streamed msgId -> index in [_items].
  Map<String, int> _byMsg = <String, int>{};

  /// streamed thinkId -> index in [_items].
  Map<String, int> _byThink = <String, int>{};

  /// Media ids the prose of one row shows, per row index. Kept per row so a
  /// changed message rescans only its own text (see [_noteMedia]).
  Map<int, Set<String>> _mediaInRow = <int, Set<String>>{};

  /// How many rows show each media id. A count, not a set: two messages may
  /// show the same image, and the first one to change must not unhide it.
  Map<String, int> _shownMedia = <String, int>{};

  /// The rows to render: the fold, minus every media bubble whose bytes a
  /// message already shows inline (see [_noteMedia]).
  ///
  /// A fresh list per call, because the store hands it to Riverpod as the new
  /// value of `chatItemsProvider`.
  List<ChatItem> get rows {
    if (_shownMedia.isEmpty) return List<ChatItem>.of(_items);
    return List<ChatItem>.of(
      _items.where(
        (i) => i is! AgentMediaItem || !_shownMedia.containsKey(i.mediaId),
      ),
    );
  }

  /// How many rows the fold holds, media bubbles included.
  int get length => _items.length;

  void addAll(Iterable<SessionEvent> events) {
    for (final e in events) {
      add(e);
    }
  }

  /// Record which media ids row [index] shows, and keep [_shownMedia] in step.
  ///
  /// A message's text grows by append and is replaced once by the final event,
  /// so the row's set is recomputed and diffed rather than merged: an id the
  /// final text drops must lose its count, or its bubble stays hidden forever.
  void _noteMedia(int index, String text) {
    final found = <String>{};
    for (final m in _mediaUriPattern.allMatches(text)) {
      found.add(m.group(1)!);
    }
    final had = _mediaInRow[index] ?? const <String>{};
    if (found.isEmpty && had.isEmpty) return;
    for (final id in had) {
      if (found.contains(id)) continue;
      final n = (_shownMedia[id] ?? 1) - 1;
      if (n <= 0) {
        _shownMedia.remove(id);
      } else {
        _shownMedia[id] = n;
      }
    }
    for (final id in found) {
      if (had.contains(id)) continue;
      _shownMedia[id] = (_shownMedia[id] ?? 0) + 1;
    }
    if (found.isEmpty) {
      _mediaInRow.remove(index);
    } else {
      _mediaInRow[index] = found;
    }
  }

  /// Fold one event in.
  void add(SessionEvent e) {
    final items = _items;
    final byCall = _byCall;
    final byMsg = _byMsg;
    final byThink = _byThink;
    switch (e.kind) {
      case EventKind.userMessage:
        items.add(
          UserMessageItem(
            seq: e.seq,
            ts: e.ts,
            text: e.payload['text'] as String? ?? '',
            attachments: MediaAttachmentRef.parseList(e.payload['attachments']),
            steered: e.payload['steered'] == true,
          ),
        );
      case EventKind.agentMessage:
        // Final (authoritative) message. Finalizes the streamed msgId's bubble
        // in place, or appends a fresh (non-streamed) bubble when there is none.
        final msgId = e.payload['msgId'] as String?;
        final text = e.payload['text'] as String? ?? '';
        final row = _upsertStream<AgentMessageItem>(
          items,
          byMsg,
          msgId,
          () => AgentMessageItem(seq: e.seq, ts: e.ts, text: text),
          (cur) => cur.copyWith(text: text, streaming: false),
          register: false,
        );
        if (row != null) _noteMedia(row, text);
      case EventKind.agentMessageDelta:
        // Streaming token. Append to the bubble for this msgId, creating it on
        // the first delta.
        final msgId = e.payload['msgId'] as String? ?? '';
        final chunk = e.payload['chunk'] as String? ?? '';
        final row = _upsertStream<AgentMessageItem>(
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
        if (row != null) {
          _noteMedia(row, (items[row] as AgentMessageItem).text);
        }
      case EventKind.agentMedia:
        // Defensive: only a well-formed content hash is fetchable (the server's
        // /media route and MediaEndpoint.urlFor both require exactly this
        // shape), and an id that fails at fetch time renders the permanent
        // broken placeholder this guard exists to avoid.
        final mediaId = e.payload['mediaId'];
        if (mediaId is String && isMediaId(mediaId)) {
          items.add(
            AgentMediaItem(
              seq: e.seq,
              ts: e.ts,
              mediaId: mediaId,
              mime: e.payload['mime'] as String? ?? 'image/png',
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
            lastTs: e.ts,
          ),
          (cur) => cur.copyWith(text: cur.text + chunk, lastTs: e.ts),
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
              ? ThinkingItem(seq: e.seq, ts: e.ts, text: text, lastTs: e.ts)
              : null,
          (cur) => cur.copyWith(text: text, streaming: false, lastTs: e.ts),
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
            endedTs: e.ts,
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
      case EventKind.sessionUsage:
        // Context/cost snapshot (SPEC-context-usage) — handled by store, rendered as chrome.
        break;
    }
  }
}

/// `makit-media:<sha256>` as the server writes it into rewritten markdown.
///
/// A real turn produces both a media bubble and the prose that shows it: the
/// agent reads an image (→ `agent.media`) and then displays it with markdown,
/// which the server rewrote to `makit-media:<mediaId>`. Rendering both puts the
/// same screenshot in the transcript twice, so [ChatItemFold.rows] drops the
/// bubble. `mediaId` is a content hash, so an identical id is provably identical
/// bytes — and a different id is a genuinely different image (a harness may hand
/// the model a downscaled copy of a huge screenshot), which stays visible.
final RegExp _mediaUriPattern = RegExp(r'makit-media:([a-f0-9]{64})');
