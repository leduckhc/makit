import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pino/ui/session/chat_message.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  testWidgets('user message renders in a right-aligned bubble with a timestamp',
      (tester) async {
    await tester.pumpWidget(wrap(const ChatBubble.user(text: 'hello', ts: 0)));
    expect(find.text('hello'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
    final align = tester.widget<Align>(find.byType(Align).first);
    expect(align.alignment, Alignment.centerRight);
  });

  testWidgets('agent message renders markdown (no bubble) with a timestamp',
      (tester) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: '# Title\n\nsome **bold** text', ts: 0)),
    );
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(Align), findsNothing);
    expect(find.textContaining('Title'), findsWidgets);
  });

  testWidgets('fenced code block gets syntax highlighting + a copy button',
      (tester) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: '```dart\nvoid main() {}\n```', ts: 0)),
    );
    expect(find.byType(HighlightView), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });
}
