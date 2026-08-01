// T10 — SPEC-34: the sticky breadcrumb.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/chat_items.dart';
import 'package:makit/ui/session/navigator/breadcrumb.dart';
import 'package:makit/ui/session/navigator/message_navigator_overlay.dart';
import 'package:makit/ui/session/navigator/navigator_style.dart';
import 'package:makit/ui/session/transcript_list.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// 7 user prompts, each followed by an agent reply and a tool call, so the user
/// messages sit at item positions 0, 3, 6, … and the full text is unique per
/// prompt (so `find.text` can pick out which one the chip is showing).
List<ChatItem> _transcript() {
  const prompts = <String>[
    'prompt zero',
    'prompt one',
    'prompt two',
    'prompt three',
    'prompt four',
    'prompt five',
    'prompt six',
  ];
  final items = <ChatItem>[];
  var seq = 0;
  for (final text in prompts) {
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

  Future<void> pumpCrumb(
    WidgetTester tester, {
    BreadcrumbOptions options = const BreadcrumbOptions(),
    MessageNavigatorStyle style = MessageNavigatorStyle.breadcrumb,
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
          breadcrumbOptionsProvider.overrideWithValue(options),
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

  IconButton chevron(WidgetTester tester, IconData icon) =>
      tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

  double dimOpacity(WidgetTester tester) => tester
      .widget<Opacity>(find.byKey(const ValueKey('breadcrumb-dim')))
      .opacity;

  testWidgets('the label tracks the governing prompt as you scroll', (
    tester,
  ) async {
    await pumpCrumb(tester);

    // Scrolled to the oldest end: the first prompt governs the viewport.
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('prompt zero'), findsOneWidget);

    // Pinned to the newest: a later prompt governs, so the label has moved on.
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('prompt zero'), findsNothing);
  });

  testWidgets('chevrons move one prompt at a time', (tester) async {
    await pumpCrumb(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('prompt zero'), findsOneWidget);

    await tester.tap(
      find.widgetWithIcon(IconButton, PhosphorIconsLight.caretRight),
    );
    await tester.pumpAndSettle();
    expect(find.text('prompt zero'), findsNothing);
    expect(find.text('prompt one'), findsOneWidget);

    await tester.tap(
      find.widgetWithIcon(IconButton, PhosphorIconsLight.caretRight),
    );
    await tester.pumpAndSettle();
    expect(find.text('prompt two'), findsOneWidget);

    await tester.tap(
      find.widgetWithIcon(IconButton, PhosphorIconsLight.caretLeft),
    );
    await tester.pumpAndSettle();
    expect(find.text('prompt one'), findsOneWidget);
  });

  testWidgets('chevrons clamp and disable at both ends', (tester) async {
    await pumpCrumb(tester);

    // Oldest end: previous is disabled and does nothing.
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('prompt zero'), findsOneWidget);
    expect(chevron(tester, PhosphorIconsLight.caretLeft).onPressed, isNull);
    await tester.tap(
      find.widgetWithIcon(IconButton, PhosphorIconsLight.caretLeft),
    );
    await tester.pumpAndSettle();
    expect(find.text('prompt zero'), findsOneWidget);

    // Walk to the newest prompt; next then disables.
    for (var i = 0; i < 6; i++) {
      await tester.tap(
        find.widgetWithIcon(IconButton, PhosphorIconsLight.caretRight),
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('prompt six'), findsOneWidget);
    expect(chevron(tester, PhosphorIconsLight.caretRight).onPressed, isNull);
  });

  testWidgets('counter: false hides the count', (tester) async {
    await pumpCrumb(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('1/7'), findsOneWidget);

    await pumpCrumb(tester, options: const BreadcrumbOptions(counter: false));
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('1/7'), findsNothing);
  });

  testWidgets(
    'autoHide dims at the newest end and restores after scrolling up',
    (tester) async {
      await pumpCrumb(tester);

      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(dimOpacity(tester), lessThan(1.0));

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(dimOpacity(tester), 1.0);
    },
  );

  testWidgets('autoHide: false never dims', (tester) async {
    await pumpCrumb(tester, options: const BreadcrumbOptions(autoHide: false));
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(dimOpacity(tester), 1.0);
  });

  testWidgets('tapping the label jumps to the governing prompt', (
    tester,
  ) async {
    await pumpCrumb(tester);
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    // At the newest end a mid-transcript prompt governs the viewport.
    expect(find.text('prompt three'), findsOneWidget);

    await tester.tap(find.text('prompt three'));
    await tester.pumpAndSettle();
    // The tap jumped to that prompt, moving it to the top of the viewport.
    expect(controller.offset, greaterThan(0));
    expect(find.text('prompt three'), findsOneWidget);
  });

  testWidgets('every control carries a screen-reader label', (tester) async {
    await pumpCrumb(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Previous message'), findsOneWidget);
    expect(find.bySemanticsLabel('Next message'), findsOneWidget);
    expect(find.bySemanticsLabel('Your message 1 of 7'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('style off renders no breadcrumb at all', (tester) async {
    await pumpCrumb(tester, style: MessageNavigatorStyle.off);
    expect(find.byType(MessageBreadcrumb), findsNothing);
  });

  testWidgets('a transcript with no user messages renders no breadcrumb', (
    tester,
  ) async {
    await pumpCrumb(
      tester,
      items: [AgentMessageItem(seq: 0, ts: 0, text: 'only me')],
    );
    expect(find.byType(MessageBreadcrumb), findsNothing);
  });

  testWidgets('hopping all the way to the newest prompt shows THAT prompt — '
      'the clamped tail, where the target cannot reach the top of the '
      'viewport', (tester) async {
    await pumpCrumb(tester);
    // Walk forward to the end.
    for (var i = 0; i < 10; i++) {
      final next = find.bySemanticsLabel('Next message');
      if (next.evaluate().isEmpty) break;
      await tester.tap(next, warnIfMissed: false);
      await tester.pumpAndSettle();
    }
    expect(find.text('prompt six'), findsWidgets);
    expect(
      find.textContaining('7/7'),
      findsOneWidget,
      reason: 'the counter must agree with the label at the clamped tail',
    );
  });
}
