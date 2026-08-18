/// The pending queue must not live INSIDE the composer.
///
/// It used to be passed into `Composer` as a child, so it rendered inside the
/// composer's own glass surface: every queued message inflated the composer box
/// and ate the room the transcript and the input field need. "Above the
/// composer" has to mean *above*, not *within*.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer.dart';
import 'package:makit/ui/composer/pending_queue.dart';
import 'package:makit/ui/composer/pending_queue_slot.dart';

const _sid = 's1';

Widget _host(List<QueuedMessage> queued) {
  final container = ProviderContainer(
    overrides: [
      queuedMessagesProvider(_sid).overrideWithValue(queued),
      commandsProvider(_sid).overrideWithValue(const []),
    ],
  );
  addTearDown(container.dispose);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            // Exactly how both surfaces mount it: a sibling ABOVE the composer.
            const PendingQueueSlot(sessionId: _sid),
            Composer(onSend: (_) {}),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a growing queue does not change the composer\'s size', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const []));
    await tester.pumpAndSettle();
    final empty = tester.getRect(find.byType(Composer));

    await tester.pumpWidget(
      _host(const [
        QueuedMessage(id: 'q1', text: 'one', queuedAt: 0),
        QueuedMessage(id: 'q2', text: 'two', queuedAt: 0),
        QueuedMessage(id: 'q3', text: 'three', queuedAt: 0),
      ]),
    );
    await tester.pumpAndSettle();
    final withQueue = tester.getRect(find.byType(Composer));

    expect(find.byType(PendingBubble), findsNWidgets(3));
    expect(
      withQueue.height,
      empty.height,
      reason:
          'three queued messages must not inflate the composer '
          '(${empty.height} → ${withQueue.height})',
    );
  });

  testWidgets('the queue renders outside the Composer subtree', (tester) async {
    await tester.pumpWidget(
      _host(const [QueuedMessage(id: 'q1', text: 'one', queuedAt: 0)]),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PendingBubble), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(Composer),
        matching: find.byType(PendingBubble),
      ),
      findsNothing,
      reason: 'inside the composer, the queue eats the composer\'s space',
    );
  });

  testWidgets('Composer takes no queue child at all', (tester) async {
    // A compile-time guarantee is better than a runtime assertion: with no
    // `pendingQueue` parameter, no caller can put the queue back inside.
    await tester.pumpWidget(_host(const []));
    await tester.pumpAndSettle();
    final composer = tester.widget<Composer>(find.byType(Composer));
    expect(
      composer.toDiagnosticsNode().getProperties().every(
        (p) => p.name != 'pendingQueue',
      ),
      isTrue,
    );
  });

  testWidgets('a disabled composer (inline ask) does not hide the queue', (
    tester,
  ) async {
    // The messages still exist and must stay cancellable while an ask owns the
    // composer — otherwise one fires when the ask is answered with no way to
    // have stopped it. As a sibling this is structural rather than a favour the
    // composer does (SPEC-mid-turn-steering-and-queue/38).
    final container = ProviderContainer(
      overrides: [
        queuedMessagesProvider(_sid).overrideWithValue(const [
          QueuedMessage(id: 'q1', text: 'waiting', queuedAt: 0),
        ]),
        commandsProvider(_sid).overrideWithValue(const []),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const PendingQueueSlot(sessionId: _sid),
                Composer(
                  onSend: (_) {},
                  enabled: false,
                  disabledHint: 'Answer above…',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PendingBubble), findsOneWidget);
    expect(find.text('Answer above…'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
