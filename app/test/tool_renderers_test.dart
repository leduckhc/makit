/// Tests for the tool renderer registry — proves the lookup, card defaults,
/// and the edit-diff detail view without spinning up a simulator.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/store/models.dart';
import 'package:pino/transport/protocol.dart';
import 'package:pino/ui/session/tool_renderers.dart';

ToolCallItem _tool(String name, Map<String, dynamic> args) => ToolCallItem(
  seq: 1,
  ts: 0,
  callId: 'c1',
  name: name,
  args: args,
  ended: true,
);

void main() {
  group('rendererFor', () {
    test('returns the matching renderer by tool name', () {
      expect(rendererFor(_tool('read', {})), isNotNull);
      expect(rendererFor(_tool('edit', {})), isNotNull);
      expect(rendererFor(_tool('bash', {})), isNotNull);
      expect(rendererFor(_tool('grep', {})), isNotNull);
      expect(rendererFor(_tool('write', {})), isNotNull);
    });

    test('returns null for unknown tools (caller falls back to generic)', () {
      expect(rendererFor(_tool('mystery_tool', {})), isNull);
    });
  });

  group('built-in renderers — subtitle extraction', () {
    test('read shows the file path', () {
      final r = rendererFor(_tool('read', {'path': '/etc/hosts'}))!;
      expect(r.subtitle(_tool('read', {'path': '/etc/hosts'})), '/etc/hosts');
    });

    test('bash truncates long commands', () {
      final cmd = 'echo ${'x' * 200}';
      final s = rendererFor(
        _tool('bash', {'command': cmd}),
      )!.subtitle(_tool('bash', {'command': cmd}));
      expect(s, isNotNull);
      expect(s!.length, lessThan(cmd.length));
      expect(s.endsWith('…'), isTrue);
    });

    test('grep includes pattern and glob', () {
      final s = rendererFor(
        _tool('grep', {'pattern': 'TODO', 'glob': '*.dart'}),
      )!.subtitle(_tool('grep', {'pattern': 'TODO', 'glob': '*.dart'}));
      expect(s, 'TODO · glob:*.dart');
    });
  });

  group('edit renderer detail view', () {
    testWidgets('renders − Removed / + Added diff blocks', (tester) async {
      final item = _tool('edit', {
        'path': 'lib/foo.dart',
        'oldText': 'final x = 1;',
        'newText': 'final x = 2;',
      });
      final renderer = rendererFor(item)!;
      // Build with a real context, not the throwaway expression we tried first.
      // Build with a real context:
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('lib/foo.dart'), findsOneWidget);
      expect(find.textContaining('Removed'), findsOneWidget);
      expect(find.textContaining('Added'), findsOneWidget);
      expect(find.text('final x = 1;'), findsOneWidget);
      expect(find.text('final x = 2;'), findsOneWidget);
    });

    testWidgets('accepts old/new aliases as well as oldText/newText', (
      tester,
    ) async {
      final item = _tool('edit', {'path': 'p', 'old': 'A', 'new': 'B'});
      final renderer = rendererFor(item)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });
  });

  group('foldEvents — tool result plumbing', () {
    test('tool.call.end output + summary flow into the ToolCallItem', () {
      SessionEvent ev(EventKind kind, Map<String, dynamic> payload, int seq) =>
          SessionEvent(seq: seq, sessionId: 's', ts: 0, kind: kind, payload: payload);

      final items = foldEvents([
        ev(EventKind.toolCallStart, {'callId': 'c1', 'name': 'read', 'args': {'path': 'x'}}, 1),
        ev(EventKind.toolCallEnd, {
          'callId': 'c1',
          'exitCode': 0,
          'summary': 'first line',
          'output': 'first line\nsecond line',
        }, 2),
      ]);

      final tool = items.whereType<ToolCallItem>().single;
      expect(tool.ended, isTrue);
      expect(tool.summary, 'first line');
      expect(tool.output, 'first line\nsecond line');
      expect(tool.exitCode, 0);
    });
  });
}
