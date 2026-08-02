import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/transport/protocol.dart';

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
      expect(tool.risk, ToolRisk.risky);
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

    test('agent.message deltas fold into one streaming bubble', () {
      final items = foldEvents([
        _ev(1, EventKind.agentMessageDelta, {'msgId': 'm1', 'chunk': 'Hel'}),
        _ev(2, EventKind.agentMessageDelta, {'msgId': 'm1', 'chunk': 'lo'}),
      ]);
      expect(items.length, 1);
      final msg = items.single as AgentMessageItem;
      expect(msg.text, 'Hello');
      expect(msg.streaming, true);
      expect(msg.msgId, 'm1');
    });

    test('final agent.message finalizes the streamed bubble in place', () {
      final items = foldEvents([
        _ev(1, EventKind.agentMessageDelta, {'msgId': 'm1', 'chunk': 'Hel'}),
        _ev(2, EventKind.agentMessageDelta, {'msgId': 'm1', 'chunk': 'lo'}),
        _ev(3, EventKind.agentMessage, {'msgId': 'm1', 'text': 'Hello!'}),
      ]);
      expect(items.length, 1, reason: 'final must replace, not append');
      final msg = items.single as AgentMessageItem;
      expect(msg.text, 'Hello!', reason: 'authoritative text wins');
      expect(msg.streaming, false);
    });

    test(
      'agent.message without a msgId is a standalone (non-streamed) bubble',
      () {
        final items = foldEvents([
          _ev(1, EventKind.agentMessage, {'text': 'plain'}),
        ]);
        expect(items.length, 1);
        final msg = items.single as AgentMessageItem;
        expect(msg.text, 'plain');
        expect(msg.streaming, false);
      },
    );

    test('two separate streamed messages fold to two bubbles', () {
      final items = foldEvents([
        _ev(1, EventKind.agentMessageDelta, {'msgId': 'a', 'chunk': 'one'}),
        _ev(2, EventKind.agentMessage, {'msgId': 'a', 'text': 'one'}),
        _ev(3, EventKind.agentMessageDelta, {'msgId': 'b', 'chunk': 'two'}),
        _ev(4, EventKind.agentMessage, {'msgId': 'b', 'text': 'two'}),
      ]);
      expect(items.length, 2);
      expect((items[0] as AgentMessageItem).text, 'one');
      expect((items[1] as AgentMessageItem).text, 'two');
      expect(
        items.every((i) => (i as AgentMessageItem).streaming == false),
        true,
      );
    });

    test('streamed thinking deltas fold into one card, finalized in place', () {
      final items = foldEvents([
        _ev(1, EventKind.agentThinkingDelta, {'thinkId': 't', 'chunk': 'pon'}),
        _ev(2, EventKind.agentThinkingDelta, {'thinkId': 't', 'chunk': 'der'}),
        _ev(3, EventKind.agentThinking, {'thinkId': 't', 'text': 'ponder'}),
      ]);
      expect(items.length, 1);
      final think = items.single as ThinkingItem;
      expect(think.text, 'ponder');
      expect(think.streaming, false);
    });

    test('non-streamed agent.thinking (no thinkId) is a standalone card', () {
      final items = foldEvents([
        _ev(1, EventKind.agentThinking, {'text': 'pondering'}),
      ]);
      expect(items.length, 1);
      expect((items.single as ThinkingItem).text, 'pondering');
    });

    test('empty-final guard: blank standalone thinking adds nothing', () {
      final items = foldEvents([
        _ev(1, EventKind.agentThinking, {'text': '   '}),
      ]);
      expect(items, isEmpty);
    });

    test('empty-final thinking still finalizes a streamed card in place', () {
      final items = foldEvents([
        _ev(1, EventKind.agentThinkingDelta, {'thinkId': 't', 'chunk': 'pon'}),
        _ev(2, EventKind.agentThinking, {'thinkId': 't', 'text': ''}),
      ]);
      expect(items.length, 1);
      final think = items.single as ThinkingItem;
      expect(think.text, '');
      expect(think.streaming, false);
    });

    test('a tool delta with no preceding start creates no card', () {
      final items = foldEvents([
        _ev(1, EventKind.toolCallDelta, {'callId': 'ghost', 'chunk': 'x'}),
      ]);
      expect(items, isEmpty);
    });

    test('tool start defaults missing risk to safe', () {
      final items = foldEvents([
        _ev(1, EventKind.toolCallStart, {'callId': 'c', 'name': 'read'}),
      ]);
      expect((items.single as ToolCallItem).risk, ToolRisk.safe);
    });

    test('tool start parses an unknown risk string to safe', () {
      final items = foldEvents([
        _ev(1, EventKind.toolCallStart, {
          'callId': 'c',
          'name': 'read',
          'risk': 'nonsense',
        }),
      ]);
      expect((items.single as ToolCallItem).risk, ToolRisk.safe);
    });

    test(
      'streamed thinking renders above an answer that streams before it ends',
      () {
        // Mirrors the GPT-5/Responses ordering: the answer\'s first delta
        // arrives before thinking is finalized. Because thinking is anchored
        // at its first delta, its card still precedes the answer bubble.
        final items = foldEvents([
          _ev(1, EventKind.agentThinkingDelta, {'thinkId': 't', 'chunk': 're'}),
          _ev(2, EventKind.agentMessageDelta, {'msgId': 'm', 'chunk': 'ans'}),
          _ev(3, EventKind.agentThinking, {'thinkId': 't', 'text': 'reason'}),
          _ev(4, EventKind.agentMessage, {'msgId': 'm', 'text': 'answer'}),
        ]);
        expect(items.length, 2);
        expect(items[0], isA<ThinkingItem>());
        expect(items[1], isA<AgentMessageItem>());
        expect((items[0] as ThinkingItem).text, 'reason');
        expect((items[1] as AgentMessageItem).text, 'answer');
      },
    );
    test('agent.media folds into a media item with its descriptor', () {
      final items = foldEvents([
        _ev(1, EventKind.agentMedia, {
          'mediaId': 'a' * 64,
          'mime': 'image/png',
          'kind': 'image',
          'alt': 'shot.png',
          'callId': 'c1',
        }),
      ]);
      expect(items.single, isA<AgentMediaItem>());
      final m = items.single as AgentMediaItem;
      expect(m.mediaId, 'a' * 64);
      expect(m.mime, 'image/png');
      expect(m.alt, 'shot.png');
      expect(m.callId, 'c1');
    });

    test('agent.media without a usable mediaId is dropped, not rendered', () {
      // Defensive boundary: a descriptor we cannot fetch must not become an
      // item that renders a permanent broken placeholder. The id must be a
      // sha256 — the same shape MediaEndpoint.urlFor will accept — because a
      // malformed one fails at fetch time, i.e. exactly the broken placeholder
      // this guard exists to avoid.
      final items = foldEvents([
        _ev(1, EventKind.agentMedia, {'mime': 'image/png'}),
        _ev(2, EventKind.agentMedia, {'mediaId': '', 'mime': 'image/png'}),
        _ev(3, EventKind.agentMedia, {'mediaId': 42, 'mime': 'image/png'}),
        _ev(4, EventKind.agentMedia, {'mediaId': 'not-a-hash'}),
        _ev(5, EventKind.agentMedia, {'mediaId': 'a' * 63}),
        _ev(6, EventKind.agentMedia, {'mediaId': 'A' * 64}),
        _ev(7, EventKind.agentMedia, {'mediaId': '${'a' * 63}?'}),
      ]);
      expect(items, isEmpty);
    });

    test('agent.media tolerates a missing mime/alt', () {
      final items = foldEvents([
        _ev(1, EventKind.agentMedia, {'mediaId': 'b' * 64}),
      ]);
      final m = items.single as AgentMediaItem;
      expect(m.mime, 'image/png', reason: 'a sane default keeps it renderable');
      expect(m.alt, isNull);
      expect(m.callId, isNull);
    });
    test(
      'a media bubble is dropped when the prose displays the same bytes',
      () {
        // Real pi turn: the agent reads an image (→ agent.media) and then shows
        // it with markdown, which the server rewrote to makit-media:<id>. The
        // mediaId is a content hash, so an identical id means identical bytes —
        // rendering both would show the screenshot twice in a row.
        final items = foldEvents([
          _ev(1, EventKind.agentMedia, {
            'mediaId': 'a' * 64,
            'mime': 'image/png',
            'callId': 'c1',
          }),
          _ev(2, EventKind.agentMessage, {
            'text': "here it is\n\n![shot](makit-media:${'a' * 64})",
          }),
        ]);
        expect(items.length, 1);
        expect(items.single, isA<AgentMessageItem>());
      },
    );

    test('a media bubble survives when the prose never shows those bytes', () {
      // The common case: the agent looked at an image but did not display it.
      // Different bytes hash differently, so a *different* id is a different
      // image (pi hands the model a downscaled copy of a large screenshot) and
      // both are legitimately shown.
      final items = foldEvents([
        _ev(1, EventKind.agentMedia, {
          'mediaId': 'a' * 64,
          'mime': 'image/png',
        }),
        _ev(2, EventKind.agentMessage, {
          'text': "shown below\n\n![other](makit-media:${'b' * 64})",
        }),
        _ev(3, EventKind.agentMessage, {'text': 'no image at all'}),
      ]);
      expect(items.whereType<AgentMediaItem>().length, 1);
    });
  });
}
