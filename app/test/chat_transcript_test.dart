/// Proves the mobile and desktop transcripts render the *same* item set by
/// construction: both go through [chatItemWidget], which maps a representative
/// list of [ChatItem]s to the expected widget types.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/session/ask_card.dart';
import 'package:makit/ui/session/chat_message.dart';
import 'package:makit/ui/session/chat_metrics.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/tool_call_card.dart';
import 'package:makit/ui/session/transcript_expansion.dart';
import 'package:makit/ui/widgets/pulse_spinner.dart';
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
      children: [
        for (final item in items) transcriptRow(chatItemWidget('s1', item)),
      ],
    ),
  ),
);

void main() {
  testWidgets('chatItemWidget maps each item to its widget type', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(child: _transcript(_representativeItems())),
    );
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
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ThinkingLine(text: 'reasoning trace', expansionKey: 'k'),
          ),
        ),
      ),
    );
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text('reasoning trace'));
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('a running tool call spins on the shared clock, not at vsync', (
    tester,
  ) async {
    // One Material spinner is one vsync ticker, and this one is on screen for
    // most of every turn — enough to undo the PulseClock saving on its own.
    final item = ToolCallItem(
      seq: 1,
      ts: 0,
      callId: 'c1',
      name: 'bash',
      args: const {'command': 'echo hi'},
      ended: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ToolCallCard(item: item, expansionKey: 'k'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(item.status, ToolStatus.running);
    expect(find.byType(PulseSpinner), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
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
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ToolCallCard(item: item, expansionKey: 'k'),
          ),
        ),
      ),
    );
    await tester.pump();

    // Collapsed: shows the one-liner summary, no body sections yet.
    expect(find.text('Run echo', findRichText: true), findsOneWidget);
    expect(find.text('Command'), findsNothing);

    await tester.tap(find.text('Run echo', findRichText: true));
    await tester.pumpAndSettle();

    // Expanded: the payload appears inside a bounded scroll region, and the
    // header KEEPS its subject (that is what lets the body drop its arguments
    // section — mockups/tool-expanded-body.html §3).
    expect(find.byType(ToolCodeBlock), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(find.text('Run echo', findRichText: true), findsOneWidget);
    expect(find.text('Run', findRichText: true), findsNothing);

    // Tapping the header again collapses it.
    await tester.tap(find.text('Run echo', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byType(ToolCodeBlock), findsNothing);
    expect(find.text('Run echo', findRichText: true), findsOneWidget);
  });

  testWidgets('disclosure caret is hidden until the row is hovered', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
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
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ToolCallCard(item: item, expansionKey: 'k'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      double caretOpacity() =>
          tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;
      expect(caretOpacity(), 0);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(ToolCallCard)));
      await tester.pumpAndSettle();
      expect(caretOpacity(), 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('hovering an expanded tool body does not crash the Scrollbar', (
    tester,
  ) async {
    // The bug is desktop-only: Material scrollbars are hover-interactive on
    // macOS/desktop, so reproduce under that platform. Reset before the body
    // ends (framework asserts foundation vars are unset), hence try/finally.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final item = ToolCallItem(
        seq: 1,
        ts: 0,
        callId: 'c1',
        name: 'bash',
        args: const {'command': 'echo hi'},
        // Long output so the body overflows kToolExpandedMaxHeight and the
        // Scrollbar thumb becomes interactive (hover would otherwise no-op).
        output: List.generate(200, (i) => 'line $i').join('\n'),
        ended: true,
        exitCode: 0,
      );
      // Outer transcript uses its OWN controller (like the real surfaces), so
      // the PrimaryScrollController is empty. A bare inner Scrollbar would grab
      // that empty controller and assert on hover; the dedicated body
      // controller prevents it.
      final outer = ScrollController();
      addTearDown(outer.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ListView(
                controller: outer,
                children: [transcriptRow(chatItemWidget('s1', item))],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Run echo', findRichText: true));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(ToolCallCard)));
      await tester.pumpAndSettle();
      // Then over the scrollbar thumb at the body's right edge.
      final rect = tester.getRect(find.byType(ToolCallCard));
      await gesture.moveTo(Offset(rect.right - 2, rect.center.dy));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
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
    final a = bash('a', 'cat a.txt');
    final b = bash('b', 'wc -l b.txt');
    var items = <ChatItem>[a];
    late StateSetter setOuter;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
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
                        child: transcriptRow(chatItemWidget('s1', it)),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // Expand call 'a'.
    await tester.tap(find.text('Run cat', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byType(ToolCodeBlock), findsOneWidget);

    // A new tool call 'b' streams in and becomes the newest (slot 0). Without
    // keying by callId, Flutter would reuse slot-0 state and 'b' would appear
    // expanded instead of 'a'.
    setOuter(() => items = [a, b]);
    await tester.pumpAndSettle();

    expect(find.text('Run wc', findRichText: true), findsOneWidget);
    // Exactly one body is expanded, and it is still 'a' (code 'cat a.txt').
    expect(find.byType(ToolCodeBlock), findsOneWidget);
    final codes = tester
        .widgetList<ToolCodeBlock>(find.byType(ToolCodeBlock))
        .map((w) => w.code)
        .toList();
    expect(codes, contains('cat a.txt'));
    expect(codes, isNot(contains('wc -l b.txt')));
  });

  testWidgets('WorkingIndicator shows the shimmer word (no spinner)', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: WorkingIndicator())),
      ),
    );
    await tester.pump();
    // The shimmer picks one work-flavoured word and masks it with a gradient;
    // there is no CircularProgressIndicator on any surface.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.text('working…'), findsNothing);
  });

  group(
    'trailerFor prioritises an awaiting ask over the working indicator',
    () {
      test(
        'awaiting wins even while running (avoids the invisible-ask deadlock)',
        () {
          expect(
            trailerFor(running: true, awaiting: true),
            TranscriptTrailer.ask,
          );
          expect(
            trailerFor(running: false, awaiting: true),
            TranscriptTrailer.ask,
          );
          expect(
            trailerFor(running: true, awaiting: false),
            TranscriptTrailer.working,
          );
          expect(
            trailerFor(running: false, awaiting: false),
            TranscriptTrailer.none,
          );
        },
      );
    },
  );

  testWidgets('answered ask_user renders as a resolved card, not a tool row', (
    tester,
  ) async {
    final item = ToolCallItem(
      seq: 1,
      ts: 0,
      callId: 'c1',
      name: 'ask_user',
      args: const {
        'question': 'Which CI?',
        'options': [
          {'label': 'GitHub Actions'},
          {'label': 'CircleCI'},
        ],
      },
      details: const {
        'answers': ['GitHub Actions'],
      },
      ended: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: Scaffold(body: chatItemWidget('s1', item))),
      ),
    );
    await tester.pump();
    expect(find.byType(AnsweredAskCard), findsOneWidget);
    expect(find.byType(ToolCallCard), findsNothing);
  });

  testWidgets('an unfold outlives the row that was tapped', (tester) async {
    // Unfolding is user intent, so it lives in [toolExpansionsProvider] rather
    // than in the row's State: the lazy transcript drops rows that scroll out
    // of its cache and rebuilds the pane on every tab/split/session change, and
    // none of that may re-fold a tool the user opened.
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
    final container = ProviderContainer();
    addTearDown(container.dispose);
    Widget app(Widget child) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    );

    await tester.pumpWidget(app(ToolCallCard(item: item, expansionKey: 'k')));
    await tester.tap(find.text('Run echo', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byType(ToolCodeBlock), findsOneWidget);

    // The row is destroyed and a brand-new one is built for the same call.
    await tester.pumpWidget(app(const SizedBox.shrink()));
    await tester.pumpWidget(app(ToolCallCard(item: item, expansionKey: 'k')));
    await tester.pumpAndSettle();

    expect(find.byType(ToolCodeBlock), findsOneWidget);
  });

  test('expansion keys are scoped per session', () {
    // Agents number their tool calls per session, so an unscoped callId would
    // make unfolding a tool in one session unfold an unrelated row in another.
    final call = ToolCallItem(
      seq: 1,
      ts: 0,
      callId: 'call_1',
      name: 'bash',
      args: const {},
    );
    expect(
      transcriptRowExpansionKey('s1', call),
      isNot(transcriptRowExpansionKey('s2', call)),
    );
    final thinking = ThinkingItem(seq: 7, ts: 0, text: 'why');
    expect(
      transcriptRowExpansionKey('s1', thinking),
      isNot(transcriptRowExpansionKey('s2', thinking)),
    );
  });

  testWidgets('an unfolded reasoning line stays unfolded when rebuilt', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    Widget app(Widget child) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    );
    const row = ThinkingLine(text: 'a reasoning trace', expansionKey: 'k');

    await tester.pumpWidget(app(row));
    await tester.tap(find.text('a reasoning trace'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);

    await tester.pumpWidget(app(const SizedBox.shrink()));
    await tester.pumpWidget(app(row));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
  });
}
