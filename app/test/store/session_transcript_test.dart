// The transcript must fold incrementally, and the result must be identical to a
// fold from scratch.
//
// Why it matters: `foldEvents` + `deriveTurns` + `withTurnReceipts` are O(events)
// and ran on every store update, so a turn cost O(events^2). `fold_bench.dart`
// measured 2.54 ms per delta at 20000 prior events. [SessionTranscript] keeps
// the folded rows and extends them with the new events only.
//
// Every test here compares `extend` against `SessionTranscript.of` on the same
// stream: equivalence is the whole contract.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/store/transcript.dart';
import 'package:makit/store/turns.dart';
import 'package:makit/transport/protocol.dart';

int _seq = 0;

SessionEvent _ev(EventKind kind, Map<String, dynamic> payload, {int? ts}) =>
    SessionEvent(
      seq: ++_seq,
      sessionId: 's1',
      ts: ts ?? 1700000000000 + _seq * 1000,
      kind: kind,
      payload: payload,
    );

/// A full turn: user asks, agent thinks, calls a tool, answers, goes idle.
List<SessionEvent> _turn({required String tag}) => [
  _ev(EventKind.userMessage, {'text': 'do $tag'}),
  _ev(EventKind.sessionStatus, const {'status': 'running'}),
  _ev(EventKind.agentThinkingDelta, {'thinkId': 'th-$tag', 'chunk': 'let me '}),
  _ev(EventKind.agentThinkingDelta, {'thinkId': 'th-$tag', 'chunk': 'think'}),
  _ev(EventKind.agentThinking, {'thinkId': 'th-$tag', 'text': 'let me think'}),
  _ev(EventKind.toolCallStart, {
    'callId': 'c-$tag',
    'name': 'bash',
    'args': {'cmd': 'ls'},
    'risk': 'safe',
  }),
  _ev(EventKind.toolCallDelta, {'callId': 'c-$tag', 'chunk': 'a.txt\n'}),
  _ev(EventKind.toolCallEnd, {
    'callId': 'c-$tag',
    'exitCode': 0,
    'summary': '1 file',
  }),
  _ev(EventKind.agentMessageDelta, {'msgId': 'm-$tag', 'chunk': 'Found '}),
  _ev(EventKind.agentMessageDelta, {'msgId': 'm-$tag', 'chunk': 'one file'}),
  _ev(EventKind.agentMessage, {'msgId': 'm-$tag', 'text': 'Found one file'}),
  _ev(EventKind.sessionStatus, const {'status': 'idle'}),
];

/// Describe rows in a comparable form: the type, the seq and the text.
List<String> _shape(List<ChatItem> rows) => [
  for (final r in rows)
    switch (r) {
      UserMessageItem(:final seq, :final text) => 'user#$seq:$text',
      AgentMessageItem(:final seq, :final text, :final streaming) =>
        'agent#$seq:$text:${streaming ? 'live' : 'done'}',
      ThinkingItem(:final seq, :final text, :final streaming) =>
        'think#$seq:$text:${streaming ? 'live' : 'done'}',
      ToolCallItem(:final seq, :final name, :final ended, :final deltas) =>
        'tool#$seq:$name:${ended ? 'end' : 'run'}:${deltas.join()}',
      AgentMediaItem(:final seq, :final mediaId) => 'media#$seq:$mediaId',
      ErrorItem(:final seq, :final message) => 'err#$seq:$message',
      TurnReceiptItem(:final seq, :final wallMs, :final toolCount) =>
        'receipt#$seq:$wallMs:$toolCount',
    },
];

/// Feed [events] one at a time and compare with one whole-stream fold.
void expectSameAsScratch(List<SessionEvent> events, {int chunk = 1}) {
  var incremental = SessionTranscript.empty;
  for (var i = 0; i < events.length; i += chunk) {
    incremental = incremental.extend(
      events.sublist(i, (i + chunk).clamp(0, events.length)),
    );
  }
  final scratch = SessionTranscript.of(events);
  expect(_shape(incremental.rows), _shape(scratch.rows));
  expect(
    incremental.turns.map((t) => '${t.openSeq}-${t.closeSeq}:${t.wallMs}'),
    scratch.turns.map((t) => '${t.openSeq}-${t.closeSeq}:${t.wallMs}'),
  );
  expect(incremental.openTurnStartMs, scratch.openTurnStartMs);
}

void main() {
  setUp(() => _seq = 0);

  test('an empty transcript has no rows and no open turn', () {
    expect(SessionTranscript.empty.rows, isEmpty);
    expect(SessionTranscript.empty.turns, isEmpty);
    expect(SessionTranscript.empty.openTurnStartMs, isNull);
  });

  test('one event at a time matches a whole-stream fold', () {
    expectSameAsScratch([..._turn(tag: 'a'), ..._turn(tag: 'b')]);
  });

  test('batches of five match a whole-stream fold', () {
    expectSameAsScratch([
      ..._turn(tag: 'a'),
      ..._turn(tag: 'b'),
      ..._turn(tag: 'c'),
    ], chunk: 5);
  });

  test('an unfinished turn keeps its streaming rows and open start', () {
    final events = [
      _ev(EventKind.userMessage, const {'text': 'go'}),
      _ev(EventKind.sessionStatus, const {'status': 'running'}),
      _ev(EventKind.agentMessageDelta, const {'msgId': 'm1', 'chunk': 'wor'}),
      _ev(EventKind.agentMessageDelta, const {'msgId': 'm1', 'chunk': 'king'}),
    ];
    expectSameAsScratch(events);

    final t = SessionTranscript.of(events);
    expect(t.turns, isEmpty, reason: 'the turn has not closed');
    expect(t.openTurnStartMs, events.first.ts);
    expect(_shape(t.rows), ['user#1:go', 'agent#3:working:live']);
  });

  test('a gated turn keeps the same gate arithmetic as a scratch fold', () {
    expectSameAsScratch([
      _ev(EventKind.userMessage, const {'text': 'risky'}),
      _ev(EventKind.sessionStatus, const {'status': 'running'}),
      _ev(EventKind.toolCallStart, const {'callId': 'c1', 'name': 'rm'}),
      _ev(EventKind.sessionStatus, const {'status': 'awaiting-approval'}),
      _ev(EventKind.sessionStatus, const {'status': 'running'}),
      _ev(EventKind.toolCallEnd, const {'callId': 'c1', 'exitCode': 0}),
      _ev(EventKind.agentMessage, const {'msgId': 'm1', 'text': 'done'}),
      _ev(EventKind.sessionStatus, const {'status': 'idle'}),
    ]);
  });

  test('a media bubble a later message shows inline stays hidden', () {
    const id =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final events = [
      _ev(EventKind.userMessage, const {'text': 'look'}),
      _ev(EventKind.sessionStatus, const {'status': 'running'}),
      _ev(EventKind.agentMedia, const {'mediaId': id, 'mime': 'image/png'}),
      _ev(EventKind.agentMessageDelta, const {
        'msgId': 'm1',
        'chunk': 'here: ![](makit-media:',
      }),
      _ev(EventKind.agentMessageDelta, const {'msgId': 'm1', 'chunk': '$id)'}),
      _ev(EventKind.sessionStatus, const {'status': 'idle'}),
    ];
    expectSameAsScratch(events);

    final rows = SessionTranscript.of(events).rows;
    expect(
      rows.whereType<AgentMediaItem>(),
      isEmpty,
      reason: 'the prose already shows those bytes',
    );
  });

  test('a media bubble no message shows stays visible', () {
    const id =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final events = [
      _ev(EventKind.agentMedia, const {'mediaId': id, 'mime': 'image/png'}),
      _ev(EventKind.agentMessage, const {'msgId': 'm1', 'text': 'a shot'}),
    ];
    expectSameAsScratch(events);
    expect(
      SessionTranscript.of(events).rows.whereType<AgentMediaItem>().length,
      1,
    );
  });

  test('rows are a new list per extend, so watchers see a change', () {
    final first = SessionTranscript.empty.extend([
      _ev(EventKind.userMessage, const {'text': 'one'}),
    ]);
    final second = first.extend([
      _ev(EventKind.userMessage, const {'text': 'two'}),
    ]);
    expect(identical(first.rows, second.rows), isFalse);
    expect(
      first.rows.length,
      1,
      reason: 'the earlier snapshot must not grow behind its holder',
    );
  });

  test('extend with nothing returns the same instance', () {
    final t = SessionTranscript.of([
      _ev(EventKind.userMessage, const {'text': 'one'}),
    ]);
    expect(identical(t.extend(const []), t), isTrue);
  });

  test('the fold still matches the standalone functions', () {
    final events = [..._turn(tag: 'a'), ..._turn(tag: 'b')];
    final t = SessionTranscript.of(events);
    expect(
      _shape(t.rows),
      _shape(withTurnReceipts(foldEvents(events), deriveTurns(events))),
    );
  });
}
