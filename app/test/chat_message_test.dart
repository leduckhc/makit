import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/chat_message.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  /// Selects everything in the agent message and returns what a copy would put
  /// on the clipboard (captured off the platform channel).
  Future<String> copyAll(WidgetTester tester) async {
    // Let the markdown lay out and register its selectables before selecting.
    await tester.pump();
    final state = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    state.selectAll();
    await tester.pump();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    // Trigger the same copy path as Cmd/Ctrl+C (non-deprecated).
    Actions.invoke(
      tester.element(find.byType(MarkdownBody)),
      CopySelectionTextIntent.copy,
    );
    await tester.pump();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    return copied ?? '';
  }

  testWidgets(
    'user message renders in a right-aligned bubble with a timestamp',
    (tester) async {
      await tester.pumpWidget(
        wrap(const ChatBubble.user(text: 'hello', ts: 0)),
      );
      expect(find.text('hello'), findsOneWidget);
      expect(find.byType(MarkdownBody), findsNothing);
      final align = tester.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.centerRight);
    },
  );

  testWidgets('agent message renders markdown (no bubble) with a timestamp', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: '# Title\n\nsome **bold** text', ts: 0)),
    );
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(Align), findsNothing);
    expect(find.textContaining('Title'), findsWidgets);
  });

  testWidgets('fenced code block gets syntax highlighting + a copy button', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: '```dart\nvoid main() {}\n```', ts: 0)),
    );
    expect(find.byType(HighlightView), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsOneWidget);
  });

  testWidgets(
    'agent markdown is wrapped in one SelectionArea with selectable:false '
    'so a single drag spans lines and inline code',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const AgentMessage(
            text: 'first line with `inline` code\n\nsecond paragraph',
            ts: 0,
          ),
        ),
      );

      // A single SelectionArea must wrap the markdown: MarkdownBody's own
      // per-block SelectableText can't select across paragraphs or over the
      // custom inline-code widget.
      final md = find.byType(MarkdownBody);
      expect(md, findsOneWidget);
      expect(
        find.ancestor(of: md, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      // Selection is delegated to the SelectionArea, not per-block widgets.
      expect(tester.widget<MarkdownBody>(md).selectable, isFalse);
    },
  );

  testWidgets('copying multiple blocks separates them with newlines', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: 'para one\n\npara two', ts: 0)),
    );
    expect(await copyAll(tester), 'para one\npara two');
  });

  testWidgets('copying inline code keeps it on the same line (no newline)', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const AgentMessage(text: 'start `code` end', ts: 0)),
    );
    expect(await copyAll(tester), 'start code end');
  });
}
