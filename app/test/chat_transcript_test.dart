/// Proves the mobile and desktop transcripts render the *same* item set by
/// construction: both go through [chatItemWidget], so a representative list of
/// [ChatItem]s maps to the identical widget types in either cosmetic mode.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/session/chat_message.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/tool_call_card.dart';

List<ChatItem> _representativeItems() => [
  UserMessageItem(seq: 1, ts: 0, text: 'hi'),
  AgentMessageItem(seq: 2, ts: 0, text: 'hello'),
  ThinkingItem(seq: 3, ts: 0, text: 'pondering'),
  ToolCallItem(seq: 4, ts: 0, callId: 'c1', name: 'read', args: const {}),
  ErrorItem(seq: 5, ts: 0, message: 'boom'),
];

Widget _transcript(List<ChatItem> items, {required bool compact}) =>
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            for (final item in items)
              chatItemWidget(item, onOpenTool: (_) {}, compact: compact),
          ],
        ),
      ),
    );

void main() {
  testWidgets('mobile and desktop render the identical item widget set', (
    tester,
  ) async {
    final items = _representativeItems();

    Future<List<Type>> renderTypes({required bool compact}) async {
      await tester.pumpWidget(_transcript(items, compact: compact));
      await tester.pump();
      return [
        if (find.byType(ChatBubble).evaluate().isNotEmpty) ChatBubble,
        if (find.byType(AgentMessage).evaluate().isNotEmpty) AgentMessage,
        if (find.byType(ThinkingLine).evaluate().isNotEmpty) ThinkingLine,
        if (find.byType(ToolCallCard).evaluate().isNotEmpty) ToolCallCard,
        if (find.byType(ErrorBanner).evaluate().isNotEmpty) ErrorBanner,
      ];
    }

    final mobile = await renderTypes(compact: false);
    final desktop = await renderTypes(compact: true);

    expect(mobile, [
      ChatBubble,
      AgentMessage,
      ThinkingLine,
      ToolCallCard,
      ErrorBanner,
    ]);
    expect(desktop, mobile, reason: 'same item set by construction');
  });

  testWidgets('ThinkingLine folds/expands in both cosmetic modes', (
    tester,
  ) async {
    for (final compact in const [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ThinkingLine(
              key: ValueKey('think-$compact'),
              text: 'reasoning trace',
              compact: compact,
            ),
          ),
        ),
      );
      expect(find.byType(SelectableText), findsNothing);
      await tester.tap(find.text('reasoning trace'));
      await tester.pump();
      expect(find.byType(SelectableText), findsOneWidget);
    }
  });

  testWidgets('WorkingIndicator: shimmer on mobile, plain label on desktop', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WorkingIndicator(key: ValueKey('wi-compact'), compact: true),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('working…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: WorkingIndicator(key: ValueKey('wi-shimmer'))),
      ),
    );
    await tester.pump();
    // The mobile shimmer picks one work-flavoured word (no spinner).
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ShaderMask), findsOneWidget);
  });

  testWidgets(
    'WorkingIndicator survives a compact→shimmer toggle on the same State',
    (tester) async {
      // Same key = same State object across rebuilds. A State created with
      // compact:true must still be able to render the shimmer (which needs the
      // animation controller) when the widget is updated to compact:false.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WorkingIndicator(key: ValueKey('wi-toggle'), compact: true),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('working…'), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WorkingIndicator(key: ValueKey('wi-toggle'), compact: false),
          ),
        ),
      );
      await tester.pump();

      // Reusing the State must not dereference a null controller.
      expect(tester.takeException(), isNull);
      expect(find.byType(ShaderMask), findsOneWidget);
    },
  );
}
