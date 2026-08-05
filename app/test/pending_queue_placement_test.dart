/// SPEC-38 — placement: the pending queue renders in exactly one of two slots,
/// chosen by a preference that both surfaces read.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/prefs/preference_entries.dart';
import 'package:makit/store/prefs/preferences_providers.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/pending_queue.dart';
import 'package:makit/ui/composer/pending_queue_slot.dart';
import 'package:makit/ui/composer/pending_queue_tray.dart';
import 'package:makit/ui/settings/pending_queue_setting.dart';

const _sid = 's1';

Widget _host({
  required PendingQueuePlacement placement,
  List<QueuedMessage> queued = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      queuedMessagesProvider(_sid).overrideWithValue(queued),
      commandsProvider(_sid).overrideWithValue(const []),
    ],
  );
  addTearDown(container.dispose);
  container
      .read(preferencesControllerProvider.notifier)
      .set(pendingQueuePlacementPreference, placement);
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            PendingQueueSlot(
              sessionId: _sid,
              slot: PendingQueuePlacement.inline,
            ),
            Spacer(),
            PendingQueueSlot(
              sessionId: _sid,
              slot: PendingQueuePlacement.pinned,
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  test(
    'the placement preference defaults to pinned — the visible-always floor',
    () {
      expect(
        pendingQueuePlacementPreference.defaultValue,
        PendingQueuePlacement.pinned,
      );
    },
  );

  test('an unknown stored value falls back to the default, never crashes', () {
    expect(pendingQueuePlacementPreference.decode('sideways'), isNull);
    expect(pendingQueuePlacementPreference.decode(7), isNull);
    expect(
      pendingQueuePlacementPreference.decode('inline'),
      PendingQueuePlacement.inline,
    );
  });

  testWidgets('pinned renders in the composer slot only', (tester) async {
    await tester.pumpWidget(
      _host(
        placement: PendingQueuePlacement.pinned,
        queued: [const QueuedMessage(id: 'q1', text: 'waiting', queuedAt: 0)],
      ),
    );
    await tester.pumpAndSettle();

    final slots = tester
        .widgetList<PendingQueueSlot>(find.byType(PendingQueueSlot))
        .toList();
    expect(slots.length, 2, reason: 'both slots are mounted; one renders');
    final rendered = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is PendingQueueSlot && w.slot == PendingQueuePlacement.pinned,
      ),
      matching: find.byType(PendingBubble),
    );
    expect(rendered, findsOneWidget);
    expect(
      find.byType(PendingBubble),
      findsOneWidget,
      reason: 'exactly one place',
    );
  });

  testWidgets('inline renders in the transcript slot only', (tester) async {
    await tester.pumpWidget(
      _host(
        placement: PendingQueuePlacement.inline,
        queued: [const QueuedMessage(id: 'q1', text: 'waiting', queuedAt: 0)],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w is PendingQueueSlot && w.slot == PendingQueuePlacement.inline,
        ),
        matching: find.byType(PendingBubble),
      ),
      findsOneWidget,
    );
    expect(find.byType(PendingBubble), findsOneWidget);
  });

  testWidgets('no pending messages renders nothing in either slot', (
    tester,
  ) async {
    await tester.pumpWidget(_host(placement: PendingQueuePlacement.inline));
    await tester.pumpAndSettle();
    expect(find.byType(PendingBubble), findsNothing);
  });

  testWidgets('the settings control moves the queue between slots', (
    tester,
  ) async {
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
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PendingQueueSlot(
                  sessionId: _sid,
                  slot: PendingQueuePlacement.inline,
                ),
                PendingQueuePlacementSetting(),
                PendingQueueSlot(
                  sessionId: _sid,
                  slot: PendingQueuePlacement.pinned,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Default is `pinned`: the queue is in the composer slot.
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w is PendingQueueSlot && w.slot == PendingQueuePlacement.pinned,
        ),
        matching: find.byType(PendingBubble),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('In the transcript'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w is PendingQueueSlot && w.slot == PendingQueuePlacement.inline,
        ),
        matching: find.byType(PendingBubble),
      ),
      findsOneWidget,
    );
    expect(
      find.byType(PendingBubble),
      findsOneWidget,
      reason: 'moved, not cloned',
    );
  });

  // ---- SPEC-37: the tray is a third choice, mounted above the composer -----

  testWidgets('tray placement renders the tray, and no bubbles', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        placement: PendingQueuePlacement.tray,
        queued: const [QueuedMessage(id: 'q1', text: 'waiting', queuedAt: 0)],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PendingQueueTray), findsOneWidget);
    expect(
      find.byType(PendingQueue),
      findsNothing,
      reason: 'the tray replaces the bubbles, it does not accompany them',
    );
    // Exactly one of the two mounted slots renders it — the tray lives above the
    // composer, so a second copy in the transcript would be a double-count.
    expect(find.byType(PendingQueueTray), findsOneWidget);
  });

  testWidgets('tray placement leaves the INLINE slot empty', (tester) async {
    await tester.pumpWidget(
      _host(
        placement: PendingQueuePlacement.tray,
        queued: const [QueuedMessage(id: 'q1', text: 'waiting', queuedAt: 0)],
      ),
    );
    await tester.pumpAndSettle();

    // `inlineQueueVisibleProvider` drives the transcript's trailer row; the tray
    // must not light it up, or the reversed list would shift every index for a
    // row that renders nothing (SPEC-21/34).
    final ctx = tester.element(find.byType(PendingQueueTray));
    final container = ProviderScope.containerOf(ctx);
    expect(container.read(inlineQueueVisibleProvider(_sid)), isFalse);
  });

  testWidgets('the settings control offers the tray as a third segment', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        queuedMessagesProvider(_sid).overrideWithValue(const []),
        commandsProvider(_sid).overrideWithValue(const []),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PendingQueuePlacementSetting()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Above the composer'), findsOneWidget);
    expect(find.text('In the transcript'), findsOneWidget);
    expect(find.text('Compact tray'), findsOneWidget);
  });
}
