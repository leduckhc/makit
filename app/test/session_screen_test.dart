import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:makit/store/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/session_screen.dart';
import 'package:makit/ui/session/transcript_list.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();

  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

void main() {
  testWidgets('expanded thinking can be collapsed through semantics', (
    tester,
  ) async {
    const sessionId = 's1';
    const thinking = 'A detailed reasoning trace';
    final session = Session(
      id: sessionId,
      projectId: 'p1',
      agent: 'pi',
      title: 'Session',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          projectsProvider.overrideWithValue(ProjectsState(const [])),
          sessionsProvider.overrideWithValue(SessionsState([session])),
          chatItemsProvider(
            sessionId,
          ).overrideWithValue([ThinkingItem(seq: 1, ts: 0, text: thinking)]),
          sessionMetaProvider(sessionId).overrideWithValue(null),
          sessionActionErrorProvider(sessionId).overrideWithValue(null),
          commandsProvider(sessionId).overrideWithValue(const []),
        ],
        child: const MaterialApp(home: SessionScreen(sessionId: sessionId)),
      ),
    );
    await tester.pump();

    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text(thinking));
    await tester.pump();

    final semantics = tester.getSemantics(find.byType(SelectableText));
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    semantics.owner!.performAction(semantics.id, SemanticsAction.tap);
    await tester.pump();

    expect(find.byType(SelectableText), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    required List<ChatItem> items,
    required SessionStatus status,
  }) async {
    const sessionId = 's1';
    final session = Session(
      id: sessionId,
      projectId: 'p1',
      agent: 'pi',
      title: 'Session',
      status: status,
      policy: ApprovalPolicy.askOnRisky,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          projectsProvider.overrideWithValue(ProjectsState(const [])),
          sessionsProvider.overrideWithValue(SessionsState([session])),
          chatItemsProvider(sessionId).overrideWithValue(items),
          sessionMetaProvider(sessionId).overrideWithValue(null),
          sessionActionErrorProvider(sessionId).overrideWithValue(null),
          commandsProvider(sessionId).overrideWithValue(const []),
        ],
        child: const MaterialApp(home: SessionScreen(sessionId: sessionId)),
      ),
    );
    await tester.pump();
  }

  testWidgets('reversed transcript renders oldest at top, newest at bottom', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      status: SessionStatus.idle,
      items: [
        UserMessageItem(seq: 1, ts: 0, text: 'oldest'),
        AgentMessageItem(seq: 2, ts: 0, text: 'newest'),
      ],
    );

    // Visual order is unchanged (oldest higher on screen than newest),
    // even though the underlying ListView is reversed.
    final oldestY = tester.getTopLeft(find.text('oldest')).dy;
    final newestY = tester.getTopLeft(find.text('newest')).dy;
    expect(oldestY, lessThan(newestY));
  });

  testWidgets('working indicator sits below the newest message when running', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      status: SessionStatus.running,
      items: [AgentMessageItem(seq: 1, ts: 0, text: 'newest')],
    );

    final newestY = tester.getTopLeft(find.text('newest')).dy;
    final indicatorY = tester.getTopLeft(find.byType(WorkingIndicator)).dy;
    expect(indicatorY, greaterThan(newestY));
  });

  testWidgets('working indicator disappears when the session goes idle', (
    tester,
  ) async {
    final items = [AgentMessageItem(seq: 1, ts: 0, text: 'newest')];
    await pumpScreen(tester, status: SessionStatus.running, items: items);
    expect(find.byType(WorkingIndicator), findsOneWidget);

    // The same screen transitions to idle: the trailing indicator must clear.
    await pumpScreen(tester, status: SessionStatus.idle, items: items);
    expect(find.byType(WorkingIndicator), findsNothing);
  });

  // A tall transcript so the reversed list actually overflows the viewport and
  // can be scrolled up into history (pixels > 0 on a reverse:true list).
  List<ChatItem> longTranscript() => [
    for (var i = 1; i <= 40; i++)
      UserMessageItem(seq: i, ts: 0, text: 'message #$i'),
  ];

  /// Pumps [SessionScreen] backed by a mutable item list. Returns the
  /// transcript [ScrollController] and a setter that pushes a new item list
  /// through the provider (simulating a streamed message).
  Future<(ScrollController, void Function(List<ChatItem>))> pumpStreaming(
    WidgetTester tester, {
    required List<ChatItem> initial,
  }) async {
    const sessionId = 's1';
    final itemsController = StateProvider<List<ChatItem>>((ref) => initial);
    final session = Session(
      id: sessionId,
      projectId: 'p1',
      agent: 'pi',
      title: 'Session',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          projectsProvider.overrideWithValue(ProjectsState(const [])),
          sessionsProvider.overrideWithValue(SessionsState([session])),
          chatItemsProvider(
            sessionId,
          ).overrideWith((ref) => ref.watch(itemsController)),
          sessionMetaProvider(sessionId).overrideWithValue(null),
          sessionActionErrorProvider(sessionId).overrideWithValue(null),
          commandsProvider(sessionId).overrideWithValue(const []),
        ],
        child: const MaterialApp(home: SessionScreen(sessionId: sessionId)),
      ),
    );
    await tester.pump();
    final controller = tester
        .widget<TranscriptListView>(find.byType(TranscriptListView))
        .controller;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SessionScreen)),
    );
    void push(List<ChatItem> next) =>
        container.read(itemsController.notifier).state = next;
    return (controller, push);
  }

  testWidgets('a streamed message while scrolled up does not yank to newest', (
    tester,
  ) async {
    final items = longTranscript();
    final (controller, push) = await pumpStreaming(tester, initial: items);

    // Sanity: the reversed transcript overflows and can be scrolled into
    // history (offset grows above the newest-at-0 resting position).
    expect(controller.position.maxScrollExtent, greaterThan(120));
    controller.jumpTo(300);
    await tester.pump();

    // A new message arrives while the user is reading older history.
    push([...items, AgentMessageItem(seq: 999, ts: 0, text: 'incoming')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The viewport must NOT be pulled back to the newest message (offset 0).
    expect(controller.position.pixels, greaterThan(120));
  });

  testWidgets('a streamed message while near the bottom pulls to the newest', (
    tester,
  ) async {
    final items = longTranscript();
    final (controller, push) = await pumpStreaming(tester, initial: items);

    // Nudge just above the bottom, still within the near-bottom threshold.
    controller.jumpTo(50);
    await tester.pump();

    push([...items, AgentMessageItem(seq: 999, ts: 0, text: 'incoming')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The viewport is pinned back to the newest message (offset 0).
    expect(controller.position.pixels, lessThanOrEqualTo(1.0));
  });

  /// Scrolls the reversed transcript into history until [target] is on screen,
  /// then a little further so the row sits clear of the floating bars.
  Future<void> scrollIntoHistory(
    WidgetTester tester,
    ScrollController controller,
    Finder target,
  ) async {
    for (var off = 0.0; off <= controller.position.maxScrollExtent; off += 60) {
      controller.jumpTo(off);
      await tester.pump();
      if (target.evaluate().isNotEmpty) {
        controller.jumpTo(
          (off + 240).clamp(0.0, controller.position.maxScrollExtent),
        );
        await tester.pump();
        return;
      }
    }
    fail('target never scrolled into view');
  }

  /// The screen y of the first history message currently on screen — a probe
  /// for "is the content the user is reading staying put?".
  ({String text, double dy}) probeRow(WidgetTester tester) {
    for (var i = 1; i <= 40; i++) {
      final f = find.text('message #$i');
      if (f.evaluate().length == 1) {
        return (text: 'message #$i', dy: tester.getTopLeft(f).dy);
      }
    }
    fail('no history message on screen');
  }

  testWidgets('a streamed message while scrolled up does not shift the view', (
    tester,
  ) async {
    final items = longTranscript();
    final (controller, push) = await pumpStreaming(tester, initial: items);
    controller.jumpTo(300);
    await tester.pump();

    final before = probeRow(tester);

    // A new (tall) message arrives below the viewport while the user reads
    // history: the row under inspection must not move a pixel.
    push([
      ...items,
      AgentMessageItem(seq: 999, ts: 0, text: List.filled(12, 'tok').join(' ')),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester.getTopLeft(find.text(before.text)).dy,
      moreOrLessEquals(before.dy, epsilon: 0.5),
    );
  });

  testWidgets('an incoming message mid-drag does not move the content', (
    tester,
  ) async {
    final items = longTranscript();
    final (controller, push) = await pumpStreaming(tester, initial: items);
    controller.jumpTo(300);
    await tester.pump();

    // The user is dragging through history when a message arrives below the
    // viewport. The row under their finger must not move; the scroll *offset*
    // may well change, because the transcript is reversed and everything above
    // the newest message shifts when it grows — absorbing that shift into the
    // offset is exactly what keeps the content still.
    final drag = await tester.startGesture(
      tester.getCenter(find.byType(TranscriptListView)),
    );
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    final before = probeRow(tester);

    push([...items, AgentMessageItem(seq: 999, ts: 0, text: 'incoming')]);
    await tester.pump();
    expect(
      tester.getTopLeft(find.text(before.text)).dy,
      moreOrLessEquals(before.dy, epsilon: 0.5),
    );

    await drag.up();
    await tester.pumpAndSettle();
  });

  List<ChatItem> transcriptWithTool() => [
    for (var i = 1; i <= 20; i++)
      UserMessageItem(seq: i, ts: 0, text: 'message #$i'),
    ToolCallItem(
      seq: 21,
      ts: 0,
      callId: 'c1',
      name: 'bash',
      args: const {'command': 'echo hi'},
      output: 'hi',
      ended: true,
      exitCode: 0,
    ),
    for (var i = 22; i <= 40; i++)
      UserMessageItem(seq: i, ts: 0, text: 'message #$i'),
  ];

  testWidgets('expanding a tool call keeps the tapped row in place', (
    tester,
  ) async {
    final (controller, _) = await pumpStreaming(
      tester,
      initial: transcriptWithTool(),
    );
    final header = find.text('Ran echo hi');
    await scrollIntoHistory(tester, controller, header);

    final beforeDy = tester.getTopLeft(header).dy;
    await tester.tap(header);
    await tester.pumpAndSettle();

    // The row expands downward: the header the user tapped stays put instead of
    // sliding off the top of the viewport.
    expect(
      tester.getTopLeft(find.text('Ran')).dy,
      moreOrLessEquals(beforeDy, epsilon: 1.0),
    );
  });

  testWidgets('an expanded tool call stays expanded when scrolled away', (
    tester,
  ) async {
    final (controller, _) = await pumpStreaming(
      tester,
      initial: transcriptWithTool(),
    );
    final header = find.text('Ran echo hi');
    await scrollIntoHistory(tester, controller, header);
    final at = controller.position.pixels;

    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.text('Output'), findsOneWidget);

    // Scroll far away and back: the expansion is the user's state, not a
    // side effect of the row happening to be built.
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    controller.jumpTo(at);
    await tester.pumpAndSettle();

    expect(find.text('Output'), findsOneWidget);
  });

  testWidgets('a jump-to-newest button appears once the newest scrolls off', (
    tester,
  ) async {
    final (controller, _) = await pumpStreaming(
      tester,
      initial: longTranscript(),
    );
    final jump = find.byIcon(PhosphorIconsLight.arrowDown);

    // Pinned to the newest message: nothing to jump to.
    expect(jump, findsNothing);

    controller.jumpTo(600);
    await tester.pumpAndSettle();
    expect(jump, findsOneWidget);

    // It jumps (not scrolls): one frame lands on the newest message.
    await tester.tap(jump);
    await tester.pump();
    expect(controller.position.pixels, 0);
    await tester.pumpAndSettle();
    expect(jump, findsNothing);
  });

  testWidgets('a short transcript is bottom-anchored above the composer', (
    tester,
  ) async {
    final (controller, _) = await pumpStreaming(
      tester,
      initial: [UserMessageItem(seq: 1, ts: 0, text: 'only message')],
    );

    // A transcript that fits the viewport has nothing to scroll.
    expect(controller.position.maxScrollExtent, 0);

    // Chat convention (reverse:true): a lone message sits in the lower half,
    // just above the floating composer — not pinned to the top of the screen.
    final screenH = tester.getSize(find.byType(Scaffold)).height;
    final messageY = tester.getCenter(find.text('only message')).dy;
    expect(messageY, greaterThan(screenH / 2));
  });
}
