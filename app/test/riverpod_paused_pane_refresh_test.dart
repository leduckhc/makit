/// Regression guard for the crash that killed the desktop app on 2026-07-31:
/// a `markNeedsBuild() called during build` assertion, followed by a cascade of
/// `Tried to rebuild Provider<...> multiple times in the same frame` errors and
/// a dead isolate.
///
/// Cause was in Riverpod itself, not makit. `ProviderElement.invalidateSelf`
/// (riverpod 3.4.1, `element.dart:830`) scheduled a container refresh for
/// **paused** provider elements. A pane in an inactive tab is paused — Riverpod
/// pauses a consumer's subscriptions off `TickerMode`
/// (`flutter_riverpod/src/core/consumer.dart:406`) — so when the store pushed an
/// event while a new pane was mounting its `chatItemsProvider` family element
/// mid-build, the paused pane's invalidation called
/// `UncontrolledProviderScope.setState` during the build phase. riverpod 3.4.2
/// guards that call with `isActive`.
///
/// This test therefore pins a **lower bound on the riverpod version** by
/// reproducing the shape rather than by asserting a version string: it fails on
/// 3.4.1 and passes on 3.4.2, so a downgrade cannot pass CI silently.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the store: the root every transcript derives from.
final _store = StateProvider<int>((ref) => 0);

/// Stands in for `eventsProvider` — one shared derived value.
final _events = Provider<int>((ref) => ref.watch(_store));

/// Stands in for `chatItemsProvider(sessionId)` — one element per pane.
final _items = Provider.family<int, String>((ref, id) => ref.watch(_events));

/// A pane whose subscriptions Riverpod pauses, because it sits under a disabled
/// [TickerMode] — the state of every pane in a non-active tab.
class _PausedPane extends ConsumerWidget {
  const _PausedPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Text('paused ${ref.watch(_items('paused-pane'))}');
}

/// The visible pane. Switching [id] makes its build mount a *new* family
/// element, which is what pulls a dirty `_events` through a flush mid-build.
class _VisiblePane extends ConsumerWidget {
  const _VisiblePane(this.id);

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      Text('visible ${ref.watch(_items(id))}');
}

void main() {
  testWidgets(
    'a store push while a new pane mounts does not markNeedsBuild during build',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      Widget tree({required bool withVisiblePane}) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Column(
            children: [
              // Inactive tab: paused subscriptions, element still alive.
              const TickerMode(enabled: false, child: _PausedPane()),
              if (withVisiblePane) const _VisiblePane('new-pane'),
            ],
          ),
        ),
      );

      // Every live pane sits in an inactive tab, so `_events` has only paused
      // listeners and is itself inactive.
      await tester.pumpWidget(tree(withVisiblePane: false));
      expect(tester.takeException(), isNull);

      // An event lands. The scheduler skips inactive elements
      // (`scheduler.dart:196`), so `_events` stays dirty instead of flushing.
      container.read(_store.notifier).state = 1;
      await tester.pump();
      expect(tester.takeException(), isNull);

      // The frame that killed the app: a new pane appears, and mounting its
      // `_items` element mid-build is what finally flushes the dirty `_events`
      // -- notifying the paused pane, which then asks the scope to refresh while
      // Flutter is still building.
      await tester.pumpWidget(tree(withVisiblePane: true));

      expect(
        tester.takeException(),
        isNull,
        reason: 'a paused pane must not schedule a scope refresh mid-build',
      );
    },
  );
}
