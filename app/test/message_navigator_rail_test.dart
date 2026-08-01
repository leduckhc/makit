// T7 — SPEC-34: the ripple rail.
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/ui/session/navigator/message_navigator_overlay.dart';
import 'package:makit/ui/session/navigator/navigator_style.dart';
import 'package:makit/ui/session/navigator/rail.dart';
import 'package:makit/ui/session/transcript_list.dart';

/// 24 rows, 7 of them the user's, with deliberately different lengths so the
/// length-encoding option has something to encode.
List<ChatItem> _transcript() {
  final texts = <String>[
    'short one',
    'a medium length prompt that runs past forty characters',
    'a really quite long prompt that definitely runs past the sixty character mark for w0',
    'tiny',
    'another medium length prompt, past forty characters here',
    'brief',
    'the last thing I asked, which is long enough to be a long tick by the sixty char rule',
  ];
  final items = <ChatItem>[];
  var seq = 0;
  for (final text in texts) {
    items.add(UserMessageItem(seq: seq++, ts: 0, text: text));
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

  Future<void> pumpRail(
    WidgetTester tester, {
    RailOptions options = const RailOptions(),
    MessageNavigatorStyle style = MessageNavigatorStyle.rail,
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
          railOptionsProvider.overrideWithValue(options),
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

  /// The rendered ticks, in cluster order, as (top, width).
  List<(double, double)> ticks(WidgetTester tester) {
    final found = find.descendant(
      of: find.byType(MessageRail),
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

  testWidgets('renders one tick per user message', (tester) async {
    await pumpRail(tester);
    expect(ticks(tester).length, 7);
  });

  testWidgets('spacing follows the preference', (tester) async {
    for (final spacing in const [6, 10, 14]) {
      await pumpRail(tester, options: RailOptions(spacing: spacing));
      final tops = ticks(tester).map((t) => t.$1).toList();
      for (var i = 1; i < tops.length; i++) {
        expect(
          tops[i] - tops[i - 1],
          closeTo(spacing, 0.01),
          reason: 'gap $i at spacing $spacing',
        );
      }
    }
  });

  testWidgets('tick length encodes message length, and can be uniform', (
    tester,
  ) async {
    await pumpRail(tester);
    final encoded = ticks(tester).map((t) => t.$2).toSet();
    expect(
      encoded.length,
      greaterThan(1),
      reason: 'lengths must differ when encoding is on',
    );

    await pumpRail(tester, options: const RailOptions(encodeLength: false));
    final uniform = ticks(tester).map((t) => t.$2).toSet();
    expect(uniform.length, 1, reason: 'all ticks equal when encoding is off');
  });

  testWidgets('hovering ripples: the crest is longest and neighbours fall off '
      'AND are pushed apart', (tester) async {
    // Uniform resting lengths: with length-encoding on, a short crest and a long
    // neighbour can come out equal, which would test nothing about the falloff.
    await pumpRail(tester, options: const RailOptions(encodeLength: false));
    final resting = ticks(tester);

    // Hover the 4th tick (index 3) — dead centre of a 7-tick cluster.
    const spacing = 6.0;
    final railBox = tester.getRect(find.byType(MessageRail));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(
      Offset(railBox.right - 20, railBox.top + 1 + 3 * spacing),
    );
    await tester.pumpAndSettle();

    final hovered = ticks(tester);
    final widths = hovered.map((t) => t.$2).toList();
    // Crest longest, strictly decreasing away from it.
    expect(widths[3], greaterThan(widths[2]));
    expect(widths[2], greaterThan(widths[1]));
    expect(widths[1], greaterThan(widths[0]));
    expect(widths[3], greaterThan(widths[4]));
    expect(widths[4], greaterThan(widths[5]));

    // The vertical push: neighbours move away from the crest, so the gaps
    // immediately around it grow beyond the resting spacing.
    final restingGap = resting[3].$1 - resting[2].$1;
    final hoveredGap = hovered[3].$1 - hovered[2].$1;
    expect(
      hoveredGap,
      greaterThan(restingGap),
      reason: 'the ripple must spread neighbours, not only stretch them',
    );
  });

  testWidgets('ripple: false stretches only the crest and pushes nothing', (
    tester,
  ) async {
    await pumpRail(tester, options: const RailOptions(ripple: false));
    final resting = ticks(tester);
    final railBox = tester.getRect(find.byType(MessageRail));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(Offset(railBox.right - 20, railBox.top + 1 + 3 * 6.0));
    await tester.pumpAndSettle();

    final hovered = ticks(tester);
    // Positions unchanged: no push.
    for (var i = 0; i < resting.length; i++) {
      expect(hovered[i].$1, closeTo(resting[i].$1, 0.01), reason: 'tick $i');
    }
    // Only the crest grew.
    expect(hovered[3].$2, greaterThan(resting[3].$2));
    expect(hovered[2].$2, closeTo(resting[2].$2, 0.01));
  });

  testWidgets('hovering reveals the message text; leaving hides it', (
    tester,
  ) async {
    await pumpRail(tester);
    expect(find.textContaining('the last thing I asked'), findsNothing);

    final railBox = tester.getRect(find.byType(MessageRail));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(Offset(railBox.right - 20, railBox.top + 1 + 6 * 6.0));
    await tester.pumpAndSettle();

    expect(find.textContaining('the last thing I asked'), findsOneWidget);
    expect(find.text('you · 7/7'), findsOneWidget);
  });

  testWidgets('tapping a tick jumps to that message', (tester) async {
    await pumpRail(tester);
    // The 1st user message is item 0 → child 20 of a 21-row list: far off screen.
    expect(find.text('child 20'), findsNothing);

    final railBox = tester.getRect(find.byType(MessageRail));
    await tester.tapAt(Offset(railBox.right - 20, railBox.top + 1));
    await tester.pump();

    expect(
      find.text('child 20'),
      findsOneWidget,
      reason: 'tapping the first tick must land on the oldest prompt',
    );
  });

  testWidgets('reduce motion: no animation and no push', (tester) async {
    await pumpRail(tester, disableAnimations: true);
    final resting = ticks(tester);
    final railBox = tester.getRect(find.byType(MessageRail));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(Offset(railBox.right - 20, railBox.top + 1 + 3 * 6.0));
    await tester.pump(); // a single frame: nothing to animate

    final hovered = ticks(tester);
    expect(
      hovered[3].$2,
      greaterThan(resting[3].$2),
      reason: 'crest still marks',
    );
    for (var i = 0; i < resting.length; i++) {
      expect(hovered[i].$1, closeTo(resting[i].$1, 0.01), reason: 'no push');
    }
  });

  testWidgets('every tick carries a screen-reader label', (tester) async {
    await pumpRail(tester);
    final handle = tester.ensureSemantics();
    for (var i = 1; i <= 7; i++) {
      expect(find.bySemanticsLabel('your message $i of 7'), findsOneWidget);
    }
    handle.dispose();
  });

  testWidgets('style off renders no rail at all', (tester) async {
    await pumpRail(tester, style: MessageNavigatorStyle.off);
    expect(find.byType(MessageRail), findsNothing);
  });

  testWidgets('a transcript with no user messages renders no rail', (
    tester,
  ) async {
    await pumpRail(
      tester,
      items: [AgentMessageItem(seq: 0, ts: 0, text: 'only me')],
    );
    expect(find.byType(MessageRail), findsNothing);
  });
}
