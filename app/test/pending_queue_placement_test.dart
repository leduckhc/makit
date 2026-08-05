/// SPEC-38/37 — presentation: the pending queue lives in ONE mount point (above
/// the composer) and the preference picks how it looks there — hollow ghost
/// bubbles or the compact tray.
///
/// The third option, `inline` (the queue inside the transcript's trailer row), is
/// deliberately gone: it was the only placement that had to touch SPEC-21's
/// anchoring and SPEC-34's index map, and a queue that scrolls out of view is a
/// queue you forget you armed.
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
const _queued = [QueuedMessage(id: 'q1', text: 'waiting', queuedAt: 0)];

ProviderContainer _container(PendingQueuePlacement placement) {
  final container = ProviderContainer(
    overrides: [
      queuedMessagesProvider(_sid).overrideWithValue(_queued),
      commandsProvider(_sid).overrideWithValue(const []),
    ],
  );
  addTearDown(container.dispose);
  container
      .read(preferencesControllerProvider.notifier)
      .set(pendingQueuePlacementPreference, placement);
  return container;
}

/// Both slots mounted at once, as both surfaces do: exactly one may render.
Widget _host(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          Spacer(),
          PendingQueueSlot(sessionId: _sid, slot: PendingQueuePlacement.pinned),
          PendingQueueSlot(sessionId: _sid, slot: PendingQueuePlacement.tray),
        ],
      ),
    ),
  ),
);

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
    // This is also the migration path for anyone whose device still has
    // `inline` persisted from before that option was removed: unknown name →
    // default, so a pending message always has somewhere to render.
    expect(pendingQueuePlacementPreference.decode('inline'), isNull);
    expect(pendingQueuePlacementPreference.decode('nonsense'), isNull);
    expect(pendingQueuePlacementPreference.decode(42), isNull);
    expect(
      pendingQueuePlacementPreference.decode('tray'),
      PendingQueuePlacement.tray,
    );
  });

  testWidgets('pinned renders hollow bubbles, and no tray', (tester) async {
    await tester.pumpWidget(_host(_container(PendingQueuePlacement.pinned)));
    await tester.pumpAndSettle();

    expect(find.byType(PendingBubble), findsOneWidget);
    expect(find.byType(PendingQueueTray), findsNothing);
  });

  testWidgets('tray renders the tray, and no bubbles', (tester) async {
    await tester.pumpWidget(_host(_container(PendingQueuePlacement.tray)));
    await tester.pumpAndSettle();

    expect(find.byType(PendingQueueTray), findsOneWidget);
    expect(
      find.byType(PendingBubble),
      findsNothing,
      reason: 'the tray replaces the bubbles, it does not accompany them',
    );
  });

  testWidgets('an empty queue renders nothing in either presentation', (
    tester,
  ) async {
    for (final placement in PendingQueuePlacement.values) {
      final container = ProviderContainer(
        overrides: [
          queuedMessagesProvider(_sid).overrideWithValue(const []),
          commandsProvider(_sid).overrideWithValue(const []),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(preferencesControllerProvider.notifier)
          .set(pendingQueuePlacementPreference, placement);

      await tester.pumpWidget(_host(container));
      await tester.pumpAndSettle();

      expect(find.byType(PendingBubble), findsNothing, reason: '$placement');
      expect(find.byType(PendingQueueTray), findsNothing, reason: '$placement');
    }
  });

  testWidgets('the settings control switches between the two presentations', (
    tester,
  ) async {
    final container = _container(PendingQueuePlacement.pinned);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PendingQueuePlacementSetting(),
                PendingQueueSlot(
                  sessionId: _sid,
                  slot: PendingQueuePlacement.pinned,
                ),
                PendingQueueSlot(
                  sessionId: _sid,
                  slot: PendingQueuePlacement.tray,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PendingBubble), findsOneWidget);
    expect(find.text('Above the composer'), findsOneWidget);
    expect(find.text('Compact tray'), findsOneWidget);
    expect(
      find.text('In the transcript'),
      findsNothing,
      reason: 'that option was removed',
    );

    await tester.tap(find.text('Compact tray'));
    await tester.pumpAndSettle();

    expect(find.byType(PendingQueueTray), findsOneWidget);
    expect(find.byType(PendingBubble), findsNothing);

    await tester.tap(find.text('Above the composer'));
    await tester.pumpAndSettle();

    expect(find.byType(PendingBubble), findsOneWidget);
    expect(find.byType(PendingQueueTray), findsNothing);
  });
}
