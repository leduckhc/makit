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
      children: [
        for (final item in items)
          transcriptRow(chatItemWidget(item, onOpenTool: (_) {})),
      ],
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
