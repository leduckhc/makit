/// Tests for the tool renderer registry — proves the lookup, summary lines,
/// and the inline body views (SPEC-24) without spinning up a simulator.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/ui/session/diff_view.dart';
import 'package:makit/ui/session/tool_renderers.dart';

ToolCallItem _tool(String name, Map<String, dynamic> args) => ToolCallItem(
  seq: 1,
  ts: 0,
  callId: 'c1',
  name: name,
  args: args,
  ended: true,
);

/// Pump a renderer's inline [ToolRenderer.body] inside a minimal scaffold —
/// the same content the transcript shows when a tool row is expanded.
Future<void> _pumpBody(WidgetTester tester, ToolCallItem item) async {
  final renderer = rendererFor(item)!;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ListView(children: renderer.body(ctx, item)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The `code` strings of every [ToolCodeBlock] currently on screen.
List<String> _codeBlocks(WidgetTester tester) => tester
    .widgetList<ToolCodeBlock>(find.byType(ToolCodeBlock))
    .map((b) => b.code)
    .toList();

void main() {
  group('rendererFor', () {
    test('returns the matching renderer by tool name', () {
      expect(rendererFor(_tool('read', {})), isNotNull);
      expect(rendererFor(_tool('edit', {})), isNotNull);
      expect(rendererFor(_tool('bash', {})), isNotNull);
      expect(rendererFor(_tool('grep', {})), isNotNull);
      expect(rendererFor(_tool('write', {})), isNotNull);
      expect(rendererFor(_tool('memory', {})), isNotNull);
      expect(rendererFor(_tool('skill', {})), isNotNull);
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

  group('summaryLine — the collapsed one-liner', () {
    test('bash summarises the command', () {
      expect(
        toolSummaryLine(_tool('bash', {'command': 'echo hi'})),
        'Ran echo hi',
      );
    });
    test('bash collapses multi-line commands to one line', () {
      expect(
        toolSummaryLine(_tool('bash', {'command': 'cd /x &&\n  pnpm  server'})),
        'Ran cd /x && pnpm server',
      );
    });
    test('edit/read/write/grep summarise their target', () {
      expect(
        toolSummaryLine(_tool('edit', {'path': 'lib/foo.dart'})),
        'Edited lib/foo.dart',
      );
      expect(
        toolSummaryLine(_tool('read', {'path': 'lib/foo.dart'})),
        'Read lib/foo.dart',
      );
      expect(
        toolSummaryLine(_tool('write', {'path': 'out.txt'})),
        'Wrote out.txt',
      );
      expect(toolSummaryLine(_tool('grep', {'pattern': 'TODO'})), 'Grep TODO');
    });
    test('memory/skill summarise action/name', () {
      expect(toolSummaryLine(_tool('memory', {'action': 'add'})), 'Memory add');
      expect(
        toolSummaryLine(_tool('skill', {'name': 'cavecrew'})),
        'Skill cavecrew',
      );
    });
    test('unknown tools fall back to the raw name', () {
      expect(toolSummaryLine(_tool('lint', {})), 'lint');
    });
  });

  group('languageForPath', () {
    test('maps common extensions to highlight.js languages', () {
      expect(languageForPath('lib/main.dart'), 'dart');
      expect(languageForPath('src/index.ts'), 'typescript');
      expect(languageForPath('build.sh'), 'bash');
      expect(languageForPath('data.json'), 'json');
      expect(languageForPath('README'), 'plaintext');
      expect(languageForPath('notes.unknownext'), 'plaintext');
    });
  });

  group('read renderer body', () {
    testWidgets('shows path and file content in a code block', (tester) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'read',
        args: const {'path': 'lib/main.dart'},
        output: 'void main() {}',
        ended: true,
      );
      await _pumpBody(tester, item);

      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(_codeBlocks(tester), contains('void main() {}'));
    });

    testWidgets('renders an (empty) code block when output is blank', (
      tester,
    ) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'read',
        args: const {'path': 'empty.txt'},
        output: '',
        ended: true,
      );
      await _pumpBody(tester, item);
      expect(find.byType(ToolCodeBlock), findsOneWidget);
      expect(_codeBlocks(tester), contains(''));
    });
  });

  group('write renderer body', () {
    testWidgets('shows path and written content', (tester) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'write',
        args: const {'path': 'out.txt', 'content': 'hello world'},
        ended: true,
      );
      await _pumpBody(tester, item);

      expect(find.text('out.txt'), findsOneWidget);
      expect(_codeBlocks(tester), contains('hello world'));
    });
  });

  group('bash renderer body', () {
    testWidgets('shows command and output in separate code blocks', (
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
      await _pumpBody(tester, item);

      expect(find.text('Command'), findsOneWidget);
      expect(find.text('Output'), findsOneWidget);
      final blocks = _codeBlocks(tester);
      expect(blocks, contains('echo hi'));
      expect(blocks, contains('hi'));
    });
  });

  group('grep renderer body', () {
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
      await _pumpBody(tester, item);

      expect(find.text('TODO'), findsOneWidget);
      expect(find.text('*.dart'), findsOneWidget);
      expect(_codeBlocks(tester), contains('lib/foo.dart:12: // TODO: fix'));
    });
  });

  group('edit renderer body', () {
    testWidgets('renders a line-level removed/added diff', (tester) async {
      final item = _tool('edit', {
        'path': 'lib/foo.dart',
        'oldText': 'final x = 1;',
        'newText': 'final x = 2;',
      });
      await _pumpBody(tester, item);

      expect(find.text('lib/foo.dart'), findsOneWidget);
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
      await _pumpBody(tester, item);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('accepts old_string/new_string aliases', (tester) async {
      final item = _tool('edit', {
        'path': 'p',
        'old_string': 'foo',
        'new_string': 'bar',
      });
      await _pumpBody(tester, item);
      expect(find.text('foo'), findsOneWidget);
      expect(find.text('bar'), findsOneWidget);
    });
  });

  group('generic tool body (no bespoke renderer)', () {
    testWidgets('shows args as label/value rows, never a raw JSON blob', (
      tester,
    ) async {
      final item = _tool('lint', {'fix': true, 'path': 'lib/foo.dart'});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ListView(children: genericToolBody(ctx, item)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Arguments'), findsOneWidget);
      // Values render as readable rows, not `{"fix":true,...}`.
      expect(find.text('true'), findsOneWidget);
      expect(find.textContaining('{'), findsNothing);
    });
  });

  group('memory and skill renderer bodies', () {
    testWidgets('memory titles its args Input (not Saved) and shows result', (
      tester,
    ) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'memory',
        args: const {'action': 'add', 'content': 'remember this'},
        output: 'ok',
        ended: true,
      );
      await _pumpBody(tester, item);
      expect(find.text('Input'), findsOneWidget);
      expect(find.text('Saved'), findsNothing);
      expect(find.text('remember this'), findsOneWidget);
    });

    testWidgets('skill shows its args and description', (tester) async {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'skill',
        args: const {'name': 'cavecrew'},
        output: 'how to delegate',
        ended: true,
      );
      await _pumpBody(tester, item);
      expect(find.text('Arguments'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);
      expect(find.text('how to delegate'), findsOneWidget);
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
      await _pumpBody(tester, item);

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
