/// Tests for the tool renderer registry — proves the lookup, card defaults,
/// and the edit-diff detail view without spinning up a simulator.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/ui/session/tool_renderers.dart';

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
      expect(rendererFor(_tool('askUserQuestion', {})), isNotNull);
      expect(rendererFor(_tool('AskUserQuestion', {})), isNotNull);
    });

    test('matches tool names case-insensitively', () {
      expect(rendererFor(_tool('Read', {})), isNotNull);
      expect(rendererFor(_tool('Edit', {})), isNotNull);
      expect(rendererFor(_tool('WRITE', {})), isNotNull);
      expect(rendererFor(_tool('Bash', {}))!.name, 'bash');
    });

    test('returns null for unknown tools (caller falls back to generic)', () {
      expect(rendererFor(_tool('mystery_tool', {})), isNull);
    });
  });

  group('display names', () {
    test('registered tools expose their lowercase name', () {
      expect(toolDisplayName(_tool('read', {})), 'read');
      expect(toolDisplayName(_tool('write', {})), 'write');
      expect(toolDisplayName(_tool('edit', {})), 'edit');
      expect(toolDisplayName(_tool('bash', {})), 'bash');
      expect(toolDisplayName(_tool('grep', {})), 'grep');
    });

    test('unknown tools fall back to their raw name', () {
      expect(toolDisplayName(_tool('lint', {})), 'lint');
    });
  });

  group('built-in renderers — detail views', () {
    test('rendererFor resolves the built-in tools by name', () {
      expect(rendererFor(_tool('read', {'path': '/etc/hosts'}))!.name, 'read');
      expect(rendererFor(_tool('bash', {'command': 'ls'}))!.name, 'bash');
      expect(rendererFor(_tool('grep', {'pattern': 'TODO'}))!.name, 'grep');
    });
  });

  group('read renderer detail view', () {
    testWidgets('shows path in app bar and file content', (tester) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'read',
        args: const {'path': 'lib/main.dart'},
        output: 'void main() {}',
        ended: true,
      );
      final renderer = rendererFor(item)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(find.text('void main() {}'), findsOneWidget);
    });

    testWidgets('shows (empty) when output is blank', (tester) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'read',
        args: const {'path': 'empty.txt'},
        output: '',
        ended: true,
      );
      final renderer = rendererFor(item)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('(empty)'), findsOneWidget);
    });
  });

  group('write renderer detail view', () {
    testWidgets('shows path and written content', (tester) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'write',
        args: const {'path': 'out.txt', 'content': 'hello world'},
        ended: true,
      );
      final renderer = rendererFor(item)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('out.txt'), findsOneWidget);
      expect(find.text('hello world'), findsOneWidget);
    });
  });

  group('bash renderer detail view', () {
    testWidgets('shows command and output in separate sections', (
      tester,
    ) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'bash',
        args: const {'command': 'echo hi'},
        output: 'hi',
        ended: true,
        exitCode: 0,
      );
      final renderer = rendererFor(item)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();

      // Header shows the tool's display name (lowercase), left-aligned.
      expect(find.text('bash'), findsOneWidget);
      expect(find.text('Command'), findsOneWidget);
      // The command appears both in the header subtitle and the Command section.
      expect(find.text('echo hi'), findsWidgets);
      expect(find.text('Output'), findsOneWidget);
      expect(find.text('hi'), findsOneWidget);
    });
  });

  group('grep renderer detail view', () {
    testWidgets('shows pattern, glob and results', (tester) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'grep',
        args: const {'pattern': 'TODO', 'glob': '*.dart'},
        output: 'lib/foo.dart:12: // TODO: fix',
        ended: true,
        exitCode: 0,
      );
      final renderer = rendererFor(item)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('grep'), findsOneWidget);
      // Pattern shows in the header subtitle and the params section.
      expect(find.text('TODO'), findsWidgets);
      expect(find.text('*.dart'), findsOneWidget);
      expect(find.text('lib/foo.dart:12: // TODO: fix'), findsOneWidget);
    });
  });

  group('edit renderer detail view', () {
    testWidgets('renders a line-level removed/added diff', (tester) async {
      final item = _tool('edit', {
        'path': 'lib/foo.dart',
        'oldText': 'final x = 1;',
        'newText': 'final x = 2;',
      });
      final renderer = rendererFor(item)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('lib/foo.dart'), findsOneWidget);
      // Old and new lines each render on their own diff row.
      expect(find.text('final x = 1;'), findsOneWidget);
      expect(find.text('final x = 2;'), findsOneWidget);
      // Removed gutter uses U+2212 MINUS; added uses '+'.
      expect(find.text('\u2212'), findsOneWidget);
      expect(find.text('+'), findsOneWidget);
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

    testWidgets('accepts old_string/new_string aliases', (tester) async {
      final item = _tool('edit', {
        'path': 'p',
        'old_string': 'foo',
        'new_string': 'bar',
      });
      final renderer = rendererFor(item)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();
      // Header uses the tool name, not the path.
      expect(find.text('edit'), findsOneWidget);
      expect(find.text('foo'), findsOneWidget);
      expect(find.text('bar'), findsOneWidget);
    });
  });

  group('generic tool detail (no bespoke renderer)', () {
    testWidgets('shows args as label/value rows, never a raw JSON blob', (
      tester,
    ) async {
      final item = _tool('lint', {'fix': true, 'path': 'lib/foo.dart'});
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => genericToolDetail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();

      // Raw tool name as the header title.
      expect(find.text('lint'), findsOneWidget);
      expect(find.text('Arguments'), findsOneWidget);
      // Values render as readable rows, not `{"fix":true,...}`.
      expect(find.text('true'), findsOneWidget);
      expect(find.textContaining('{'), findsNothing);
    });
  });

  group('extractToolResultText', () {
    test('pulls text out of an MCP content envelope', () {
      const raw = '{"content":[{"type":"text","text":"hello"}],"details":{}}';
      expect(extractToolResultText(raw), 'hello');
    });

    test('concatenates text across back-to-back envelopes', () {
      const raw =
          '{"content":[]}{"content":[{"type":"text","text":"one\\ntwo"}],"details":{}}';
      expect(extractToolResultText(raw), 'one\ntwo');
    });

    test('ignores non-text content parts', () {
      const raw =
          '{"content":[{"type":"image","data":"x"},{"type":"text","text":"ok"}]}';
      expect(extractToolResultText(raw), 'ok');
    });

    test('returns plain (non-envelope) output verbatim', () {
      expect(
        extractToolResultText('exit 0\nstdout here'),
        'exit 0\nstdout here',
      );
    });

    test('leaves brace-containing non-envelope JSON untouched', () {
      expect(extractToolResultText('{"error":"boom"}'), '{"error":"boom"}');
    });

    test('does not trip on braces inside string values', () {
      const raw = '{"content":[{"type":"text","text":"a { nested } brace"}]}';
      expect(extractToolResultText(raw), 'a { nested } brace');
    });
  });

  group('edit output is colour-coded like a git diff', () {
    testWidgets('renders the hashline result with a DiffText', (tester) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'edit',
        args: const {'input': '[lib/foo.dart#AB12]'},
        output:
            '[lib/foo.dart#AB12]\n 10:unchanged\n-11:final x = 1;\n+11:final x = 2;',
        ended: true,
      );
      final renderer = rendererFor(item)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (ctx) => renderer.detail(ctx, item)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DiffText), findsOneWidget);
      expect(find.text('[lib/foo.dart#AB12]'), findsOneWidget);
      expect(find.text('-11:final x = 1;'), findsOneWidget);
      expect(find.text('+11:final x = 2;'), findsOneWidget);
    });
  });

  group('foldEvents — tool result plumbing', () {
    test('tool.call.end output + summary flow into the ToolCallItem', () {
      SessionEvent ev(EventKind kind, Map<String, dynamic> payload, int seq) =>
          SessionEvent(
            seq: seq,
            sessionId: 's',
            ts: 0,
            kind: kind,
            payload: payload,
          );

      final items = foldEvents([
        ev(EventKind.toolCallStart, {
          'callId': 'c1',
          'name': 'read',
          'args': {'path': 'x'},
        }, 1),
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
