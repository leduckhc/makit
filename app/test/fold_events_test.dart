import 'package:flutter_test/flutter_test.dart';
import 'package:pino/store/models.dart';
import 'package:pino/transport/protocol.dart';

SessionEvent _ev(int seq, EventKind k, Map<String, dynamic> p) => SessionEvent(
  seq: seq,
  sessionId: 's1',
  ts: seq * 1000,
  kind: k,
  payload: p,
);

void main() {
  group('foldEvents', () {
    test('user/agent messages become bubbles in order', () {
      final items = foldEvents([
        _ev(1, EventKind.userMessage, {'text': 'hi'}),
        _ev(2, EventKind.agentMessage, {'text': 'hello'}),
      ]);
      expect(items.length, 2);
      expect(items[0], isA<UserMessageItem>());
      expect(items[1], isA<AgentMessageItem>());
      expect((items[0] as UserMessageItem).text, 'hi');
      expect((items[1] as AgentMessageItem).text, 'hello');
    });

    test('tool start + delta + end folds into one card', () {
      final items = foldEvents([
        _ev(1, EventKind.toolCallStart, {
          'callId': 'c',
          'name': 'edit',
          'args': {'path': 'x.dart'},
          'risk': 'risky',
        }),
        _ev(2, EventKind.toolCallDelta, {'callId': 'c', 'chunk': 'aaa'}),
        _ev(3, EventKind.toolCallDelta, {'callId': 'c', 'chunk': 'bbb'}),
        _ev(4, EventKind.toolCallEnd, {
          'callId': 'c',
          'exitCode': 0,
          'summary': 'ok',
        }),
      ]);
      expect(items.length, 1);
      final tool = items.single as ToolCallItem;
      expect(tool.name, 'edit');
      expect(tool.risk, 'risky');
      expect(tool.deltas.join(), 'aaabbb');
      expect(tool.ended, true);
      expect(tool.exitCode, 0);
      expect(tool.summary, 'ok');
    });

    test('interleaved tool calls fold to separate cards', () {
      final items = foldEvents([
        _ev(1, EventKind.toolCallStart, {'callId': 'a', 'name': 'read'}),
        _ev(2, EventKind.toolCallStart, {'callId': 'b', 'name': 'edit'}),
        _ev(3, EventKind.toolCallDelta, {'callId': 'a', 'chunk': 'A'}),
        _ev(4, EventKind.toolCallEnd, {'callId': 'b', 'exitCode': 0}),
        _ev(5, EventKind.toolCallEnd, {'callId': 'a', 'exitCode': 0}),
      ]);
      expect(items.length, 2);
      final a = items[0] as ToolCallItem;
      final b = items[1] as ToolCallItem;
      expect(a.callId, 'a');
      expect(a.deltas, ['A']);
      expect(b.callId, 'b');
      expect(a.ended && b.ended, true);
    });
  });
}
