import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/ui/session/chat_message.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  testWidgets('user message renders in a bubble (SelectableText, right-aligned)',
      (tester) async {
    await tester.pumpWidget(wrap(const ChatBubble.user(text: 'hello')));
    expect(find.text('hello'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
    final align = tester.widget<Align>(find.byType(Align).first);
    expect(align.alignment, Alignment.centerRight);
  });

  testWidgets('agent message renders markdown (no bubble)', (tester) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: '# Title\n\nsome **bold** text')),
    );
    expect(find.byType(MarkdownBody), findsOneWidget);
    // No Align wrapper (full-width, not bubble-aligned).
    expect(find.byType(Align), findsNothing);
    expect(find.textContaining('Title'), findsWidgets);
  });
}
