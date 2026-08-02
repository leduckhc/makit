// T11 — SPEC-34: the prompt palette — a filterable list of your own messages.
//
// The single trap this guards: `searchAll` searches every row, so a result's
// index in the *filtered* list is not its item position in the transcript.
// `jumpToItem` takes the item position; conflating the two lands you on the
// wrong row.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/ui/session/navigator/message_navigator_overlay.dart';
import 'package:makit/ui/session/navigator/navigator_style.dart';
import 'package:makit/ui/session/navigator/palette.dart';
import 'package:makit/ui/session/transcript_list.dart';

/// 8 turns → 24 rows, 8 of them the user's. Every text is unique so a filter
/// can pin down exactly one match, and the agent/tool texts are distinct from
/// the user's so `searchAll` corpus growth is observable.
List<ChatItem> _transcript() {
  const words = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven'];
  final items = <ChatItem>[];
  var seq = 0;
  for (final word in words) {
    items.add(UserMessageItem(seq: seq++, ts: 0, text: 'prompt $word'));
    items.add(AgentMessageItem(seq: seq++, ts: 0, text: 'answer $word'));
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

  Future<void> pumpPalette(
    WidgetTester tester, {
    PaletteOptions options = const PaletteOptions(),
    MessageNavigatorStyle style = MessageNavigatorStyle.palette,
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
          paletteOptionsProvider.overrideWithValue(options),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                TranscriptListView(
                  controller: controller,
                  padding: EdgeInsets.zero,
                  itemCount: transcript.length,
                  jumpTarget: target,
                  findChildIndexCallback: (key) => (key as ValueKey<int>).value,
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
    );
    await tester.pumpAndSettle();
  }

  /// Opens the palette by tapping its trigger button.
  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('Find your messages'));
    await tester.pumpAndSettle();
  }

  testWidgets('opening lists exactly the user\'s own messages', (tester) async {
    await pumpPalette(tester);
    await open(tester);
    // All eight prompts, none of the answers.
    for (final word in const ['zero', 'three', 'seven']) {
      expect(find.text('prompt $word'), findsOneWidget);
    }
    expect(find.text('answer zero'), findsNothing);
    expect(find.textContaining('prompt'), findsNWidgets(8));
  });

  testWidgets('typing narrows the results', (tester) async {
    await pumpPalette(tester);
    await open(tester);
    await tester.enterText(find.byType(TextField), 'seven');
    await tester.pumpAndSettle();
    expect(find.text('prompt seven'), findsOneWidget);
    expect(find.text('prompt zero'), findsNothing);
    expect(find.textContaining('prompt'), findsOneWidget);
  });

  testWidgets('a filter with no match shows a clear empty state', (
    tester,
  ) async {
    await pumpPalette(tester);
    await open(tester);
    await tester.enterText(find.byType(TextField), 'zzzz-no-such-thing');
    await tester.pumpAndSettle();
    expect(find.textContaining('prompt'), findsNothing);
    expect(find.text('No matching messages'), findsOneWidget);
  });

  testWidgets('arrow-down moves selection and previews without closing', (
    tester,
  ) async {
    await pumpPalette(tester);
    await open(tester);
    // Selection starts at 0 (oldest = child 23) with no jump. Arrow down →
    // selection 1 = position 3 = child 20, which is off screen initially.
    expect(find.text('child 20'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.text('child 20'), findsOneWidget, reason: 'previewed the jump');
    // The overlay stays open.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('Enter jumps to the selection and closes', (tester) async {
    await pumpPalette(tester);
    await open(tester);
    // Selection 0 = oldest prompt = child 23, off screen.
    expect(find.text('child 23'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('child 23'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'closed');
  });

  testWidgets('Escape closes without jumping', (tester) async {
    await pumpPalette(tester);
    await open(tester);
    final before = controller.position.pixels;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'closed');
    expect(controller.position.pixels, before, reason: 'no jump');
  });

  testWidgets('searchAll widens the corpus and shows a role tag per result', (
    tester,
  ) async {
    await pumpPalette(tester, options: const PaletteOptions(searchAll: true));
    await open(tester);
    // Agent + tool rows are now searchable.
    expect(find.text('answer zero'), findsOneWidget);
    // Role tags on results.
    expect(find.text('you'), findsWidgets);
    expect(find.text('agent'), findsWidgets);
    expect(find.text('tool'), findsWidgets);
  });

  testWidgets('searchAll jump lands on the correct row (item-position map)', (
    tester,
  ) async {
    await pumpPalette(tester, options: const PaletteOptions(searchAll: true));
    await open(tester);
    // "answer zero" is the first agent reply → item position 1 → child 22.
    // It is the *only* filtered result (filtered index 0), so a naive jump to
    // the filtered index would land on child 23, not child 22.
    await tester.enterText(find.byType(TextField), 'answer zero');
    await tester.pumpAndSettle();
    expect(find.text('child 22'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.text('child 22'),
      findsOneWidget,
      reason: 'item position 1, not filtered index 0',
    );
  });

  testWidgets('the trigger and results carry semantics', (tester) async {
    await pumpPalette(tester);
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Find your messages'), findsOneWidget);
    await open(tester);
    expect(find.bySemanticsLabel('prompt zero'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('style off renders no palette at all', (tester) async {
    await pumpPalette(tester, style: MessageNavigatorStyle.off);
    expect(find.byType(MessagePalette), findsNothing);
  });

  testWidgets('a transcript with no user messages renders no palette', (
    tester,
  ) async {
    await pumpPalette(
      tester,
      items: [AgentMessageItem(seq: 0, ts: 0, text: 'only me')],
    );
    expect(find.byType(MessagePalette), findsNothing);
  });
}
