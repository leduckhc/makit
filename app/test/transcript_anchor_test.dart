// Regression tests for the transcript's scroll anchoring under *realistic*
// conditions: rows of wildly different heights (the existing session-screen
// tests use uniform one-line rows, where a lazy list's extent estimate happens
// to be exact — which hides the bugs below).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/session_screen.dart';
import 'package:makit/ui/session/tool_renderers.dart' show ToolCodeBlock;
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

/// A transcript whose rows vary a lot in height, like a real session.
List<ChatItem> mixedTranscript() => [
  for (var i = 1; i <= 30; i++)
    if (i % 3 == 0)
      AgentMessageItem(
        seq: i,
        ts: 0,
        text: 'message #$i ${List.filled(40, 'word').join(' ')}',
      )
    else if (i % 3 == 1)
      UserMessageItem(seq: i, ts: 0, text: 'message #$i')
    else
      ToolCallItem(
        seq: i,
        ts: 0,
        callId: 'c$i',
        name: 'bash',
        args: {'command': 'tool$i --run'},
        output: 'out $i',
        ended: true,
        exitCode: 0,
      ),
];

void main() {
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

  /// Scrolls the reversed transcript until [target] is on screen.
  Future<void> scrollTo(
    WidgetTester tester,
    ScrollController controller,
    Finder target,
  ) async {
    for (var off = 0.0; off <= controller.position.maxScrollExtent; off += 60) {
      controller.jumpTo(off);
      await tester.pump();
      if (target.evaluate().isNotEmpty) {
        controller.jumpTo(
          (off + 200).clamp(0.0, controller.position.maxScrollExtent),
        );
        await tester.pump();
        return;
      }
    }
    fail('target never scrolled into view');
  }

  testWidgets('an expanded tool stays expanded when a new item arrives', (
    tester,
  ) async {
    final items = mixedTranscript();
    final (controller, push) = await pumpStreaming(tester, initial: items);
    final header = find.text('Run tool2', findRichText: true);
    await scrollTo(tester, controller, header);

    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(find.byType(ToolCodeBlock), findsOneWidget);

    // A new message streams in at the newest end (the reversed list's index 0).
    push([...items, AgentMessageItem(seq: 900, ts: 0, text: 'incoming')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(ToolCodeBlock),
      findsOneWidget,
      reason: 'the row the user unfolded must stay unfolded',
    );
  });

  testWidgets('a new item does not shift history with mixed row heights', (
    tester,
  ) async {
    final items = mixedTranscript();
    final (controller, push) = await pumpStreaming(tester, initial: items);
    final probe = find.text('message #10');
    await scrollTo(tester, controller, probe);
    expect(probe, findsOneWidget, reason: 'probe must be on screen to measure');
    final before = tester.getTopLeft(probe).dy;

    push([
      ...items,
      AgentMessageItem(seq: 900, ts: 0, text: List.filled(30, 'tok').join(' ')),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester.getTopLeft(probe).dy,
      moreOrLessEquals(before, epsilon: 1.0),
      reason: 'the row being read must not move',
    );
  });

  testWidgets('a long transcript stays still while items stream in', (
    tester,
  ) async {
    // 200 rows so most of the list is unbuilt: the lazy list's extent estimate
    // is then wildly wrong, which is what used to throw the viewport across the
    // conversation (up to hundreds of px per incoming item, or all the way to
    // the top when the estimate overshot).
    final items = <ChatItem>[
      for (var i = 1; i <= 200; i++)
        if (i % 4 == 0)
          AgentMessageItem(
            seq: i,
            ts: 0,
            text: 'message #$i ${List.filled(60, 'word').join(' ')}',
          )
        else
          UserMessageItem(seq: i, ts: 0, text: 'message #$i'),
    ];
    final (controller, push) = await pumpStreaming(tester, initial: items);
    final probe = find.text('message #189');
    await scrollTo(tester, controller, probe);
    expect(probe, findsOneWidget, reason: 'probe must be on screen to measure');
    final before = tester.getTopLeft(probe).dy;

    // Three items arrive, the last one very tall.
    var next = items;
    for (var n = 0; n < 3; n++) {
      next = [
        ...next,
        AgentMessageItem(
          seq: 900 + n,
          ts: 0,
          text: List.filled(n == 2 ? 400 : 5, 'tok').join(' '),
        ),
      ];
      push(next);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      tester.getTopLeft(probe).dy,
      moreOrLessEquals(before, epsilon: 1.0),
      reason: 'streaming below the viewport must not move history',
    );
  });

  testWidgets('expanding a tool keeps the tapped header in place (mixed)', (
    tester,
  ) async {
    final items = mixedTranscript();
    final (controller, _) = await pumpStreaming(tester, initial: items);
    final header = find.text('Run tool11', findRichText: true);
    await scrollTo(tester, controller, header);
    final before = tester.getTopLeft(header).dy;

    await tester.tap(header);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(header).dy,
      moreOrLessEquals(before, epsilon: 1.0),
    );
  });

  testWidgets('folding a tool again keeps the tapped header in place', (
    tester,
  ) async {
    final items = mixedTranscript();
    final (controller, _) = await pumpStreaming(tester, initial: items);
    final header = find.text('Run tool11', findRichText: true);
    await scrollTo(tester, controller, header);

    await tester.tap(header);
    await tester.pumpAndSettle();
    final expandedDy = tester.getTopLeft(header).dy;

    // Folding shrinks the row, so the correction runs the other way: the header
    // must still not move.
    await tester.tap(header);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('Run tool11', findRichText: true)).dy,
      moreOrLessEquals(expandedDy, epsilon: 1.0),
    );
  });
}
