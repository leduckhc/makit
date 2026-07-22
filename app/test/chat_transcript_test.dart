/// Proves the mobile and desktop transcripts render the *same* item set by
/// construction: both go through [chatItemWidget], which maps a representative
/// list of [ChatItem]s to the expected widget types.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/session/chat_message.dart';
import 'package:makit/ui/session/chat_metrics.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/tool_call_card.dart';
import 'package:makit/ui/session/tool_renderers.dart' show ToolCodeBlock;

List<ChatItem> _representativeItems() => [
  UserMessageItem(seq: 1, ts: 0, text: 'hi'),
  AgentMessageItem(seq: 2, ts: 0, text: 'hello'),
  ThinkingItem(seq: 3, ts: 0, text: 'pondering'),
  ToolCallItem(seq: 4, ts: 0, callId: 'c1', name: 'read', args: const {}),
  ErrorItem(seq: 5, ts: 0, message: 'boom'),
];

Widget _transcript(List<ChatItem> items) => MaterialApp(
  home: Scaffold(
    body: ListView(
      children: [for (final item in items) transcriptRow(chatItemWidget(item))],
    ),
  ),
);

void main() {
  testWidgets('chatItemWidget maps each item to its widget type', (
    tester,
  ) async {
    await tester.pumpWidget(_transcript(_representativeItems()));
    await tester.pump();

    final rendered = [
      if (find.byType(ChatBubble).evaluate().isNotEmpty) ChatBubble,
      if (find.byType(AgentMessage).evaluate().isNotEmpty) AgentMessage,
      if (find.byType(ThinkingLine).evaluate().isNotEmpty) ThinkingLine,
      if (find.byType(ToolCallCard).evaluate().isNotEmpty) ToolCallCard,
      if (find.byType(ErrorBanner).evaluate().isNotEmpty) ErrorBanner,
    ];

    expect(rendered, [
      ChatBubble,
      AgentMessage,
      ThinkingLine,
      ToolCallCard,
      ErrorBanner,
    ]);
  });

  testWidgets('ThinkingLine folds/expands on tap', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ThinkingLine(text: 'reasoning trace')),
      ),
    );
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text('reasoning trace'));
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('ToolCallCard expands its body inline on tap', (tester) async {
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ToolCallCard(item: item)),
      ),
    );
    await tester.pump();

    // Collapsed: shows the one-liner summary, no body sections yet.
    expect(find.text('Ran echo hi'), findsOneWidget);
    expect(find.text('Command'), findsNothing);

    await tester.tap(find.text('Ran echo hi'));
    await tester.pumpAndSettle();

    // Expanded: body sections appear inside a bounded scroll region.
    expect(find.text('Command'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);

    // Tapping the leading icon collapses it again.
    await tester.tap(find.byType(Icon).first);
    await tester.pumpAndSettle();
    expect(find.text('Command'), findsNothing);
  });

  testWidgets('tool expansion state follows callId, not list position', (
    tester,
  ) async {
    ToolCallItem bash(String id, String cmd) => ToolCallItem(
      seq: id.hashCode,
      ts: 0,
      callId: id,
      name: 'bash',
      args: {'command': cmd},
      output: cmd,
      ended: true,
      exitCode: 0,
    );
    final a = bash('a', 'echo a');
    final b = bash('b', 'echo b');
    var items = <ChatItem>[a];
    late StateSetter setOuter;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (ctx, setState) {
              setOuter = setState;
              // Newest-first, like the reversed transcript. Rows are keyed by
              // identity exactly as the real surfaces do.
              return ListView(
                children: [
                  for (final it in items.reversed)
                    KeyedSubtree(
                      key: chatItemKey(it),
                      child: transcriptRow(chatItemWidget(it)),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    // Expand call 'a'.
    await tester.tap(find.text('Ran echo a'));
    await tester.pumpAndSettle();
    expect(find.text('Command'), findsOneWidget);

    // A new tool call 'b' streams in and becomes the newest (slot 0). Without
    // keying by callId, Flutter would reuse slot-0 state and 'b' would appear
    // expanded instead of 'a'.
    setOuter(() => items = [a, b]);
    await tester.pumpAndSettle();

    expect(find.text('Ran echo b'), findsOneWidget);
    // Exactly one body is expanded, and it is still 'a' (code 'echo a').
    expect(find.text('Command'), findsOneWidget);
    final codes = tester
        .widgetList<ToolCodeBlock>(find.byType(ToolCodeBlock))
        .map((w) => w.code)
        .toList();
    expect(codes, contains('echo a'));
    expect(codes, isNot(contains('echo b')));
  });

  testWidgets('WorkingIndicator shows the shimmer word (no spinner)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WorkingIndicator())),
    );
    await tester.pump();
    // The shimmer picks one work-flavoured word and masks it with a gradient;
    // there is no CircularProgressIndicator on any surface.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.text('working…'), findsNothing);
  });
}
