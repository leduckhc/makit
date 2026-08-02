// SPEC-34 (mobile): the "My messages" sheet reached from session actions.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/navigator/jump_flash.dart';
import 'package:makit/ui/session/navigator/messages_sheet.dart';
import 'package:makit/ui/session/navigator/transcript_jumper.dart';
import 'package:makit/ui/session/transcript_list.dart';

List<ChatItem> _transcript() {
  const prompts = ['first thing', 'second thing', 'third thing'];
  final items = <ChatItem>[];
  var seq = 0;
  for (final text in prompts) {
    items.add(UserMessageItem(seq: seq++, ts: 0, text: text));
    items.add(AgentMessageItem(seq: seq++, ts: 0, text: 'reply $seq'));
  }
  return items;
}

void main() {
  late ScrollController controller;
  late TranscriptJumpTarget target;
  late List<int> jumped;

  /// Pumps a host with a button that opens the sheet, mirroring how the mobile
  /// session-actions menu invokes it.
  Future<ProviderContainer> pumpHost(
    WidgetTester tester, {
    List<ChatItem>? items,
  }) async {
    controller = ScrollController();
    target = TranscriptJumpTarget();
    jumped = [];
    addTearDown(controller.dispose);
    addTearDown(target.dispose);
    final transcript = items ?? _transcript();
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [chatItemsProvider('s1').overrideWithValue(transcript)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return Scaffold(
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
                        height: 200,
                        child: Text('child $i'),
                      ),
                    ),
                    Builder(
                      builder: (context) => TextButton(
                        onPressed: () => showMyMessagesSheet(
                          context: context,
                          sessionId: 's1',
                          jumper: TranscriptJumper(
                            target: target,
                            itemCount: () => transcript.length,
                            hasTrailer: () => false,
                            onFlash: (p) => jumped.add(p),
                          ),
                        ),
                        child: const Text('open'),
                      ),
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

  testWidgets('lists only the user messages, newest first', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('My messages'), findsOneWidget);
    for (final text in const ['first thing', 'second thing', 'third thing']) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(find.textContaining('reply'), findsNothing);

    // Newest first: 'third thing' must sit above 'first thing'.
    expect(
      tester.getTopLeft(find.text('third thing')).dy,
      lessThan(tester.getTopLeft(find.text('first thing')).dy),
    );
  });

  testWidgets('numbers the messages in conversation order', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Oldest is 1 even though it is rendered last.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('tapping an entry jumps to it and dismisses the sheet', (
    tester,
  ) async {
    await pumpHost(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('first thing'));
    await tester.pumpAndSettle();

    expect(jumped, [0], reason: 'the oldest prompt is item position 0');
    expect(find.text('My messages'), findsNothing, reason: 'sheet dismisses');
    expect(find.text('child 5'), findsOneWidget, reason: 'transcript moved');
  });

  testWidgets('the landing flash fires exactly once per pick — the sheet must '
      'not double-arm it on top of the jumper', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('second thing'));
    await tester.pumpAndSettle();

    expect(jumped, [2], reason: 'one flash, at the picked position');
  });

  testWidgets('an empty transcript shows an explanation, not a blank sheet', (
    tester,
  ) async {
    await pumpHost(
      tester,
      items: [AgentMessageItem(seq: 0, ts: 0, text: 'only me')],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining("haven't sent"), findsOneWidget);
  });

  testWidgets('entries carry screen-reader labels', (tester) async {
    await pumpHost(tester);
    final handle = tester.ensureSemantics();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('your message 1 of 3'), findsOneWidget);
    expect(find.bySemanticsLabel('your message 3 of 3'), findsOneWidget);
    handle.dispose();
  });

  group('JumpFlashHighlight', () {
    // This is the piece that was specified, tested at the notifier level, and
    // then rendered by nothing at all — the landing highlight never appeared on
    // screen. These tests pin the actual pixels.
    Future<ProviderContainer> pumpRow(WidgetTester tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return const Scaffold(
                  body: JumpFlashHighlight(
                    sessionId: 's1',
                    position: 7,
                    child: Text('the row'),
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

    Border? borderOf(WidgetTester tester) {
      final boxes = tester.widgetList<DecoratedBox>(find.byType(DecoratedBox));
      for (final box in boxes) {
        final decoration = box.decoration;
        if (decoration is BoxDecoration && decoration.border != null) {
          return decoration.border as Border;
        }
      }
      return null;
    }

    testWidgets('draws nothing until a jump lands on this row', (tester) async {
      final container = await pumpRow(tester);
      expect(borderOf(tester), isNull);

      // A jump to a *different* row must not highlight this one.
      recordJumpFlashOn(container, 's1', 3);
      await tester.pump();
      expect(borderOf(tester), isNull);
    });

    testWidgets('outlines the row when the jump lands here, then fades out', (
      tester,
    ) async {
      final container = await pumpRow(tester);
      recordJumpFlashOn(container, 's1', 7);
      await tester.pump();

      final border = borderOf(tester);
      expect(border, isNotNull, reason: 'the landing must be visible');
      expect(border!.top.width, 2);
      final startAlpha = border.top.color.a;

      await tester.pump(const Duration(milliseconds: 600));
      final mid = borderOf(tester)!.top.color.a;
      expect(mid, lessThan(startAlpha), reason: 'it fades');

      await tester.pumpAndSettle();
      expect(borderOf(tester)!.top.color.a, 0.0, reason: 'and is gone');
    });

    testWidgets('a second jump to the same row replays the fade', (
      tester,
    ) async {
      final container = await pumpRow(tester);
      recordJumpFlashOn(container, 's1', 7);
      await tester.pumpAndSettle();
      expect(borderOf(tester)!.top.color.a, 0.0);

      recordJumpFlashOn(container, 's1', 7);
      await tester.pump();
      expect(
        borderOf(tester)!.top.color.a,
        greaterThan(0.5),
        reason: 'the serial must restart the animation, not leave it finished',
      );
    });
  });
}

/// Records a flash straight on a container (the widget helper needs a WidgetRef).
void recordJumpFlashOn(
  ProviderContainer container,
  String sessionId,
  int position,
) {
  final notifier = container.read(jumpFlashProvider(sessionId).notifier);
  notifier.state = JumpFlash(position, (notifier.state?.serial ?? 0) + 1);
}
