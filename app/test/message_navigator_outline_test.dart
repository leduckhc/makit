// T9 — SPEC-34: outline mode.
//
// Outline is the odd one out: it does not overlay the transcript, it *filters*
// it. These tests therefore assert on which rows exist, and that leaving the
// mode puts you back where you clicked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/ui/session/navigator/message_navigator_overlay.dart';
import 'package:makit/ui/session/navigator/navigator_style.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/navigator/outline_mode.dart';
import 'package:makit/ui/session/transcript_list.dart';

List<ChatItem> _transcript() {
  final items = <ChatItem>[];
  var seq = 0;
  for (var i = 1; i <= 4; i++) {
    items.add(UserMessageItem(seq: seq++, ts: 0, text: 'prompt $i'));
    items.add(AgentMessageItem(seq: seq++, ts: 0, text: 'reply $i a'));
    items.add(
      ToolCallItem(
        seq: seq++,
        ts: 0,
        callId: 'c$i',
        name: 'bash',
        args: const {},
        ended: true,
      ),
    );
    items.add(AgentMessageItem(seq: seq++, ts: 0, text: 'reply $i b'));
  }
  return items;
}

void main() {
  group('outlineItems', () {
    test('keeps the user messages and, by default, the tool calls', () {
      final outlined = outlineItems(_transcript(), hideTools: false);
      expect(outlined.whereType<UserMessageItem>().length, 4);
      expect(outlined.whereType<ToolCallItem>().length, 4);
      expect(outlined.whereType<AgentMessageItem>(), isEmpty);
    });

    test('hideTools drops the tool calls too', () {
      final outlined = outlineItems(_transcript(), hideTools: true);
      expect(outlined.length, 4);
      expect(outlined.every((i) => i is UserMessageItem), isTrue);
    });

    test('an empty transcript outlines to nothing', () {
      expect(outlineItems(const [], hideTools: false), isEmpty);
    });
  });

  group('hiddenRowsAfter', () {
    test('counts the rows collapsed under a prompt', () {
      final items = _transcript();
      // Each prompt is followed by agent, tool, agent.
      expect(hiddenRowsAfter(items, 0, hideTools: false), 2); // 2 agent rows
      expect(hiddenRowsAfter(items, 0, hideTools: true), 3); // + the tool row
    });

    test('the last prompt counts its trailing rows', () {
      final items = _transcript();
      final last = items.lastIndexWhere((i) => i is UserMessageItem);
      expect(hiddenRowsAfter(items, last, hideTools: false), 2);
    });

    test('a prompt followed immediately by another hides nothing', () {
      final items = <ChatItem>[
        UserMessageItem(seq: 0, ts: 0, text: 'a'),
        UserMessageItem(seq: 1, ts: 0, text: 'b'),
      ];
      expect(hiddenRowsAfter(items, 0, hideTools: false), 0);
    });
  });

  group('transcriptItemsProvider', () {
    ProviderContainer containerFor({
      required MessageNavigatorStyle style,
      required bool outlineOn,
      OutlineOptions options = const OutlineOptions(),
    }) {
      final container = ProviderContainer(
        overrides: [
          messageNavigatorStyleProvider.overrideWithValue(style),
          outlineOptionsProvider.overrideWithValue(options),
          chatItemsProvider('s1').overrideWithValue(_transcript()),
        ],
      );
      if (outlineOn) {
        container.read(outlineModeProvider('s1').notifier).state = true;
      }
      addTearDown(container.dispose);
      return container;
    }

    test('passes the transcript through when outline is off', () {
      final container = containerFor(
        style: MessageNavigatorStyle.outline,
        outlineOn: false,
      );
      expect(container.read(transcriptItemsProvider('s1')).length, 16);
    });

    test('filters when outline is on', () {
      final container = containerFor(
        style: MessageNavigatorStyle.outline,
        outlineOn: true,
      );
      expect(container.read(transcriptItemsProvider('s1')).length, 8);
    });

    test('hideTools narrows it further', () {
      final container = containerFor(
        style: MessageNavigatorStyle.outline,
        outlineOn: true,
        options: const OutlineOptions(hideTools: true),
      );
      expect(container.read(transcriptItemsProvider('s1')).length, 4);
    });

    test(
      'a stale outline flag cannot hide the transcript under another style',
      () {
        // The guard that matters: switch style away while outline was on and the
        // transcript must come back intact.
        final container = containerFor(
          style: MessageNavigatorStyle.rail,
          outlineOn: true,
        );
        expect(container.read(transcriptItemsProvider('s1')).length, 16);
      },
    );
  });

  group('MessageOutline (widget)', () {
    Future<ProviderContainer> pumpOutline(
      WidgetTester tester, {
      OutlineOptions options = const OutlineOptions(),
    }) async {
      final items = _transcript();
      final controller = ScrollController();
      final target = TranscriptJumpTarget();
      addTearDown(controller.dispose);
      addTearDown(target.dispose);
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messageNavigatorStyleProvider.overrideWithValue(
              MessageNavigatorStyle.outline,
            ),
            outlineOptionsProvider.overrideWithValue(options),
            chatItemsProvider('s1').overrideWithValue(items),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                final visible = ref.watch(transcriptItemsProvider('s1'));
                return Scaffold(
                  body: Stack(
                    children: [
                      TranscriptListView(
                        controller: controller,
                        padding: EdgeInsets.zero,
                        itemCount: visible.length,
                        jumpTarget: target,
                        findChildIndexCallback: (key) =>
                            (key as ValueKey<int>).value,
                        itemBuilder: (context, i) => SizedBox(
                          key: ValueKey(i),
                          height: 60,
                          child: Text('row $i'),
                        ),
                      ),
                      MessageNavigatorOverlay(
                        sessionId: 's1',
                        controller: controller,
                        target: target,
                        items: visible,
                        hasTrailer: false,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('the toggle reports how many rows it would hide', (
      tester,
    ) async {
      await pumpOutline(tester);
      expect(find.text('outline'), findsOneWidget);

      await tester.tap(find.text('outline'));
      await tester.pumpAndSettle();

      // 16 rows, 4 of them prompts, 4 tool calls kept → 8 hidden.
      expect(find.text('outline · 8 hidden'), findsOneWidget);
    });

    testWidgets('hideTools raises the hidden count', (tester) async {
      await pumpOutline(tester, options: const OutlineOptions(hideTools: true));
      await tester.tap(find.text('outline'));
      await tester.pumpAndSettle();
      expect(find.text('outline · 12 hidden'), findsOneWidget);
    });

    testWidgets('toggling collapses the transcript and restores it', (
      tester,
    ) async {
      final container = await pumpOutline(tester);
      expect(container.read(transcriptItemsProvider('s1')).length, 16);

      await tester.tap(find.text('outline'));
      await tester.pumpAndSettle();
      expect(container.read(transcriptItemsProvider('s1')).length, 8);

      await tester.tap(find.text('outline · 8 hidden'));
      await tester.pumpAndSettle();
      expect(container.read(transcriptItemsProvider('s1')).length, 16);
    });

    testWidgets('the toggle carries a screen-reader label for both states', (
      tester,
    ) async {
      await pumpOutline(tester);
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('Outline: show only your messages'),
        findsOneWidget,
      );
      await tester.tap(find.text('outline'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Leave outline mode'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a pending exit-jump is consumed exactly once', (tester) async {
      final container = await pumpOutline(tester);
      await tester.tap(find.text('outline'));
      await tester.pumpAndSettle();

      // Simulate a tapped prompt: leave the mode and post the position.
      container.read(outlineModeProvider('s1').notifier).state = false;
      container.read(outlineExitJumpProvider('s1').notifier).state = 12;
      await tester.pumpAndSettle();

      expect(
        container.read(outlineExitJumpProvider('s1')),
        isNull,
        reason: 'the jump request must be cleared after it is performed',
      );
    });
  });

  group('mobile placement', () {
    // Mobile floats a glass top bar over the transcript. A navigator anchored at
    // the Stack's top edge would sit *behind* it — visible to `find`, but under
    // the bar and untappable. This is the bug that only appeared once mobile
    // switched from the scrubber (a full-height edge strip) to outline.
    testWidgets('the toggle clears the floating top bar', (tester) async {
      const inset = 100.0;
      final items = _transcript();
      final controller = ScrollController();
      final target = TranscriptJumpTarget();
      addTearDown(controller.dispose);
      addTearDown(target.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messageNavigatorStyleProvider.overrideWithValue(
              MessageNavigatorStyle.outline,
            ),
            chatItemsProvider('s1').overrideWithValue(items),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  const SizedBox.expand(),
                  MessageNavigatorOverlay(
                    sessionId: 's1',
                    controller: controller,
                    target: target,
                    items: items,
                    hasTrailer: false,
                    topInset: inset,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('outline')).dy,
        greaterThanOrEqualTo(inset),
        reason: 'the toggle must sit below the glass bar, not behind it',
      );
    });
  });
}
