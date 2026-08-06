// On the phone the composer is a floating overlay, so the pending queue floats
// over the transcript. The transcript's bottom padding cannot grow to compensate
// — it is the reversed list's LEADING pad, and changing it mid-session shifts
// what the user is reading (SPEC-21 anchoring; the anchor tests catch it at
// 36px). So the queue is BOUNDED instead: at most a third of the viewport,
// scrolling internally past that.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/pending_queue.dart';
import 'package:makit/ui/session/session_screen.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();

  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

const _sid = 's1';
const _viewport = Size(390, 844);

ChatItem _msg(int i) =>
    UserMessageItem(seq: i, ts: i, text: 'message number $i');

ProviderContainer _container(int queueLength) => ProviderContainer(
  overrides: [
    connectionControllerProvider.overrideWith(
      (ref) => ConnectionController(const _EmptyStorage()),
    ),
    projectsProvider.overrideWithValue(ProjectsState(const [])),
    reposProvider.overrideWithValue(ReposState(const [])),
    sessionsProvider.overrideWithValue(
      SessionsState([
        Session(
          id: _sid,
          projectId: 'p1',
          agent: 'pi',
          title: 'Session',
          status: SessionStatus.running,
          policy: ApprovalPolicy.askOnRisky,
        ),
      ]),
    ),
    chatItemsProvider(
      _sid,
    ).overrideWithValue([for (var i = 1; i <= 12; i++) _msg(i)]),
    sessionMetaProvider(_sid).overrideWithValue(null),
    sessionActionErrorProvider(_sid).overrideWithValue(null),
    commandsProvider(_sid).overrideWithValue(const []),
    queuedMessagesProvider(_sid).overrideWithValue([
      for (var i = 0; i < queueLength; i++)
        QueuedMessage(id: 'q$i', text: 'queued message number $i', queuedAt: i),
    ]),
  ],
);

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SessionScreen(sessionId: _sid)),
    ),
  );
  // NOT pumpAndSettle: the session is running, so the working indicator animates
  // forever.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {});

  testWidgets('a long queue cannot take more than a third of the screen', (
    tester,
  ) async {
    tester.view.physicalSize = _viewport * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final container = _container(12);
    addTearDown(container.dispose);
    await _pump(tester, container);

    // The scroll view is what the cap constrains; the widget adds its own 4px
    // bottom gutter on top of it.
    final scroller = tester.getRect(
      find
          .descendant(
            of: find.byType(PendingQueue),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
    );
    expect(
      scroller.height,
      lessThanOrEqualTo(_viewport.height / 3 + 1),
      reason:
          'twelve pending messages would otherwise cover the conversation '
          '(${scroller.height.toStringAsFixed(0)}px of ${_viewport.height})',
    );
    // Bounded, not truncated: the rest is reachable by scrolling the queue.
    expect(find.byType(Scrollable), findsWidgets);
  });

  testWidgets('a short queue is its natural height, not the cap', (
    tester,
  ) async {
    tester.view.physicalSize = _viewport * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final container = _container(1);
    addTearDown(container.dispose);
    await _pump(tester, container);

    final queue = tester.getRect(find.byType(PendingQueue));
    expect(queue.height, lessThan(_viewport.height / 4));
    expect(find.byType(PendingBubble), findsOneWidget);
  });
}
