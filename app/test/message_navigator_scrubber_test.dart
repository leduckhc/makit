// T8 — SPEC-34: the prompt scrubber.
//
// A narrow invisible strip down the transcript's trailing edge with one dot per
// user message. Press-drag maps the pointer to the nearest message; the crux is
// *when* the transcript scrolls: continuously under `liveScroll`, else once on
// release.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/ui/session/navigator/message_navigator_overlay.dart';
import 'package:makit/ui/session/navigator/navigator_style.dart';
import 'package:makit/ui/session/navigator/scrubber.dart';
import 'package:makit/ui/session/transcript_list.dart';

/// 7 user messages interleaved with an agent reply and a tool call each, so the
/// user's prompts sit at item positions 0, 3, 6, … 18 of a 21-row transcript.
/// [userTs] stamps every user message, so a timestamp test can make one recent.
List<ChatItem> _transcript({int userTs = 0}) {
  final texts = <String>[
    'first thing I asked',
    'second prompt',
    'third prompt',
    'fourth prompt',
    'fifth prompt',
    'sixth prompt',
    'the last thing I asked',
  ];
  final items = <ChatItem>[];
  var seq = 0;
  for (final text in texts) {
    items.add(UserMessageItem(seq: seq++, ts: userTs, text: text));
    items.add(AgentMessageItem(seq: seq++, ts: 0, text: 'reply $seq'));
    items.add(
      ToolCallItem(
        seq: seq++,
        ts: 0,
        callId: 'c$seq',
        name: 'bash',
        args: const {},
        ended: true,
      ),
    );
  }
  return items;
}

void main() {
  late ScrollController controller;
  late TranscriptJumpTarget target;

  Future<void> pumpScrubber(
    WidgetTester tester, {
    ScrubberOptions options = const ScrubberOptions(),
    MessageNavigatorStyle style = MessageNavigatorStyle.scrubber,
    bool disableAnimations = false,
    List<ChatItem>? items,
  }) async {
    controller = ScrollController();
    target = TranscriptJumpTarget();
    addTearDown(controller.dispose);
    addTearDown(target.dispose);
    final transcript = items ?? _transcript();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageNavigatorStyleProvider.overrideWithValue(style),
          scrubberOptionsProvider.overrideWithValue(options),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: Scaffold(
              body: Stack(
                children: [
                  TranscriptListView(
                    controller: controller,
                    padding: EdgeInsets.zero,
                    itemCount: transcript.length,
                    jumpTarget: target,
                    findChildIndexCallback: (key) =>
                        (key as ValueKey<int>).value,
                    itemBuilder: (context, i) => SizedBox(
                      key: ValueKey(i),
                      height: 60,
                      child: Text('child $i'),
                    ),
                  ),
                  MessageNavigatorOverlay(
                    sessionId: 's1',
                    controller: controller,
                    target: target,
                    items: transcript,
                    hasTrailer: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The rendered dots, in strip order, as (top, width).
  List<(double, double)> dots(WidgetTester tester) {
    final found = find.descendant(
      of: find.byType(MessageScrubber),
      matching: find.byType(AnimatedContainer),
    );
    return [
      for (final element in found.evaluate())
        (
          (element.renderObject! as RenderBox).localToGlobal(Offset.zero).dy,
          (element.renderObject! as RenderBox).size.width,
        ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
  }

  /// Presses at [start] on the strip and drags to [end] without releasing;
  /// returns the live gesture so a test can inspect state before `up()`.
  Future<TestGesture> dragTo(
    WidgetTester tester,
    Offset start,
    Offset end,
  ) async {
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(end);
    await tester.pump();
    return gesture;
  }

  testWidgets('renders one dot per user message', (tester) async {
    await pumpScrubber(tester);
    expect(dots(tester).length, 7);
  });

  testWidgets('dragging maps to the nearest message index', (tester) async {
    await pumpScrubber(tester);
    final box = tester.getRect(find.byType(MessageScrubber));
    final x = box.center.dx;

    final g = await dragTo(
      tester,
      Offset(x, box.bottom - 20),
      Offset(x, box.top + 20),
    );
    expect(find.text('you · 1/7'), findsOneWidget);
    await g.moveTo(Offset(x, box.center.dy));
    await tester.pump();
    expect(find.text('you · 4/7'), findsOneWidget);
    await g.moveTo(Offset(x, box.bottom - 20));
    await tester.pump();
    expect(find.text('you · 7/7'), findsOneWidget);
    await g.up();
  });

  testWidgets('liveScroll scrolls the transcript during the drag', (
    tester,
  ) async {
    await pumpScrubber(tester);
    expect(find.text('child 20'), findsNothing);

    final box = tester.getRect(find.byType(MessageScrubber));
    final x = box.center.dx;
    final g = await dragTo(
      tester,
      Offset(x, box.bottom - 20),
      Offset(x, box.top + 12),
    );
    // Live: the oldest prompt (item 0 → child 20) is on screen *before* release.
    expect(find.text('child 20'), findsOneWidget);
    await g.up();
  });

  testWidgets('without liveScroll the jump waits for release', (tester) async {
    await pumpScrubber(
      tester,
      options: const ScrubberOptions(liveScroll: false),
    );
    expect(find.text('child 20'), findsNothing);

    final box = tester.getRect(find.byType(MessageScrubber));
    final x = box.center.dx;
    final g = await dragTo(
      tester,
      Offset(x, box.bottom - 20),
      Offset(x, box.top + 12),
    );
    // The preview shows the target, but the transcript has NOT moved yet.
    expect(find.text('you · 1/7'), findsOneWidget);
    expect(
      find.text('child 20'),
      findsNothing,
      reason: 'without liveScroll nothing scrolls until release',
    );

    await g.up();
    await tester.pump();
    expect(
      find.text('child 20'),
      findsOneWidget,
      reason: 'release commits the jump',
    );
  });

  testWidgets('preview card shows the message text', (tester) async {
    await pumpScrubber(tester);
    final box = tester.getRect(find.byType(MessageScrubber));
    final x = box.center.dx;
    final g = await dragTo(
      tester,
      Offset(x, box.bottom - 20),
      Offset(x, box.top + 20),
    );
    expect(find.textContaining('first thing I asked'), findsOneWidget);
    await g.up();
  });

  testWidgets('timestamps option shows a relative time on the card', (
    tester,
  ) async {
    final recent =
        DateTime.now().millisecondsSinceEpoch -
        const Duration(minutes: 5).inMilliseconds;
    await pumpScrubber(tester, items: _transcript(userTs: recent));
    final box = tester.getRect(find.byType(MessageScrubber));
    final x = box.center.dx;
    final g = await dragTo(
      tester,
      Offset(x, box.bottom - 20),
      Offset(x, box.top + 20),
    );
    expect(find.textContaining('ago'), findsOneWidget);
    await g.up();
  });

  testWidgets('timestamps off shows no relative time', (tester) async {
    final recent =
        DateTime.now().millisecondsSinceEpoch -
        const Duration(minutes: 5).inMilliseconds;
    await pumpScrubber(
      tester,
      options: const ScrubberOptions(timestamps: false),
      items: _transcript(userTs: recent),
    );
    final box = tester.getRect(find.byType(MessageScrubber));
    final x = box.center.dx;
    final g = await dragTo(
      tester,
      Offset(x, box.bottom - 20),
      Offset(x, box.top + 20),
    );
    expect(find.textContaining('ago'), findsNothing);
    await g.up();
  });

  testWidgets('a ts==0 message shows no relative time even when enabled', (
    tester,
  ) async {
    // Default transcript stamps every user message ts:0 (fixtures).
    await pumpScrubber(tester);
    final box = tester.getRect(find.byType(MessageScrubber));
    final x = box.center.dx;
    final g = await dragTo(
      tester,
      Offset(x, box.bottom - 20),
      Offset(x, box.top + 20),
    );
    expect(
      find.textContaining('ago'),
      findsNothing,
      reason: 'ts==0 must render nothing rather than "56 years ago"',
    );
    await g.up();
  });

  testWidgets('every dot carries a screen-reader label', (tester) async {
    await pumpScrubber(tester);
    final handle = tester.ensureSemantics();
    for (var i = 1; i <= 7; i++) {
      expect(find.bySemanticsLabel('your message $i of 7'), findsOneWidget);
    }
    handle.dispose();
  });

  testWidgets('reduce motion: the hot dot grows without an animation', (
    tester,
  ) async {
    await pumpScrubber(tester, disableAnimations: true);
    final resting = dots(tester);
    final box = tester.getRect(find.byType(MessageScrubber));
    final x = box.center.dx;
    // A single frame — with animations disabled the hot dot is already large.
    final gesture = await tester.startGesture(Offset(x, box.bottom - 20));
    await gesture.moveTo(Offset(x, box.top + 20));
    await tester.pump();

    final hot = dots(tester);
    expect(
      hot.first.$2,
      greaterThan(resting.first.$2),
      reason: 'the hot (top) dot is enlarged in one frame',
    );
    await gesture.up();
  });

  testWidgets('style off renders no scrubber at all', (tester) async {
    await pumpScrubber(tester, style: MessageNavigatorStyle.off);
    expect(find.byType(MessageScrubber), findsNothing);
  });

  testWidgets('a transcript with no user messages renders no scrubber', (
    tester,
  ) async {
    await pumpScrubber(
      tester,
      items: [AgentMessageItem(seq: 0, ts: 0, text: 'only me')],
    );
    expect(find.byType(MessageScrubber), findsNothing);
  });
}
