/// Replay tests — fold REAL recorded pi-acp sessions (captured via
/// server/test/record-acp-session.ts, mapped to app-format events via
/// server/test/replay-acp-session.ts) through [foldEvents] and assert the
/// UI-facing tool one-liners. This is the deterministic seam for testing UI
/// changes against the actual wire behavior of pi (edit/write/read/grep/ls/
/// bash/ask_user/subagents) without spinning up a device or the LLM.
///
/// Fixtures live in test/fixtures/acp/*.events.json and are byte-identical to
/// server/test/fixtures/acp (enforced by Protocol Contract CI). Regenerate with:
///   (cd server && node_modules/.bin/tsx test/replay-acp-session.ts --write)
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/ui/session/tool_renderers.dart';

List<ChatItem> foldFixture(String name) {
  final raw = File('test/fixtures/acp/$name.events.json').readAsStringSync();
  final events = (jsonDecode(raw) as List)
      .map((e) => SessionEvent.fromJson(e as Map<String, dynamic>))
      .whereType<SessionEvent>()
      .toList();
  return foldEvents(events);
}

List<ToolCallItem> toolsOf(List<ChatItem> items) =>
    items.whereType<ToolCallItem>().toList();

void main() {
  group('replay real pi-acp sessions', () {
    test('bash: one tool call, command + output, completed', () {
      final tools = toolsOf(foldFixture('bash'));
      expect(tools, hasLength(1));
      final t = tools.single;
      expect(t.name, 'bash');
      // The command must be the REAL command, not the tool name "bash".
      expect(toolSummaryLine(t), 'Ran echo hello-from-pi');
      expect(t.ended, isTrue);
      expect(t.exitCode, 0);
      expect(t.resultText, contains('hello-from-pi'));
    });

    test('read/grep/ls: each carries its real target and completes', () {
      final tools = toolsOf(foldFixture('read-grep-ls'));
      final byName = {for (final t in tools) t.name: t};
      expect(byName.keys, containsAll(['read', 'grep', 'ls']));
      expect(toolSummaryLine(byName['read']!), 'Read package.json');
      expect(toolSummaryLine(byName['grep']!), 'Grep scripts');
      // ls has no bespoke renderer; the arg is still present for the body.
      expect(byName['ls']!.args['path'], 'src');
      for (final t in tools) {
        expect(t.ended, isTrue, reason: '${t.name} never completed (stuck)');
      }
    });

    test('write + edit: real paths, both completed', () {
      final tools = toolsOf(foldFixture('write-edit'));
      final byName = {for (final t in tools) t.name: t};
      expect(toolSummaryLine(byName['write']!), 'Wrote /tmp/makit-demo.txt');
      expect(toolSummaryLine(byName['edit']!), 'Edited /tmp/makit-demo.txt');
      for (final t in tools) {
        expect(t.ended, isTrue);
      }
    });

    test(
      'ask_user: no tool row — the question renders as an inline ask card',
      () {
        // pi-acp emits BOTH an `ask_user` tool call and a separate permission
        // request carrying the question; the app shows the latter as an inline
        // ask card (SPEC-25), so a tool row would just duplicate it.
        final tools = toolsOf(foldFixture('ask-user'));
        expect(tools.map((t) => t.name), isNot(contains('ask_user')));
        // And the suppressed call must not leave a headless row behind.
        expect(tools, isEmpty);
      },
    );

    test('subagent: Agent tool carries its description and completes', () {
      final tools = toolsOf(foldFixture('subagent'));
      final agent = tools.firstWhere((t) => t.name == 'Agent');
      expect(agent.args['description'], isNotEmpty);
      expect(agent.args['subagent_type'], isNotEmpty);
      expect(agent.ended, isTrue);
    });

    test('no tool is left running (regression: stuck tool call)', () {
      for (final name in [
        'bash',
        'read-grep-ls',
        'write-edit',
        'ask-user',
        'subagent',
      ]) {
        for (final t in toolsOf(foldFixture(name))) {
          expect(
            t.status,
            isNot(ToolStatus.running),
            reason: '$name: tool "${t.name}" is stuck in running state',
          );
        }
      }
    });
  });
}
