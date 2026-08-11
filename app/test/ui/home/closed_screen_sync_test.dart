// Review follow-ups on the closed screen (PR #123): the live-sync listener had
// no baseline, so the first close/restore elsewhere was swallowed, and
// pull-to-refresh returned before the reload landed, hiding the spinner
// immediately.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/closed_screen.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

Session _session(String id, {bool closed = false}) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: 'session $id',
  status: SessionStatus.exited,
  policy: ApprovalPolicy.askOnRisky,
  closed: closed,
);

/// Counts closed-list loads and lets a test hold one open.
class _FakeStore extends StoreController {
  _FakeStore(super.ref);

  int loads = 0;
  Completer<List<Session>>? gate;

  @override
  Future<List<Session>> listClosedSessions() {
    loads++;
    final g = gate;
    if (g != null) return g.future;
    return Future.value([_session('a1', closed: true)]);
  }
}

void main() {
  late StateProvider<List<Session>> active;

  ProviderContainer container(_FakeStore Function(Ref) build) {
    active = StateProvider<List<Session>>((ref) => [_session('s1')]);
    final c = ProviderContainer(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(const _EmptyStorage()),
        ),
        projectsProvider.overrideWithValue(ProjectsState(const [])),
        sessionsProvider.overrideWith(
          (ref) => SessionsState(ref.watch(active)),
        ),
        storeControllerProvider.overrideWith(build),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  testWidgets('reloads on the first close that happens elsewhere', (
    tester,
  ) async {
    late _FakeStore store;
    final c = container((ref) => store = _FakeStore(ref));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: ClosedScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.loads, 1, reason: 'initial load');

    // Somebody closes s1 on the home screen: the active list loses an id.
    c.read(active.notifier).state = const [];
    await tester.pumpAndSettle();

    expect(
      store.loads,
      2,
      reason: 'the very first change must reload, not just record a baseline',
    );
  });

  testWidgets('ignores churn that does not change the id set', (tester) async {
    late _FakeStore store;
    final c = container((ref) => store = _FakeStore(ref));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: ClosedScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Same id, new status — routine activity, not a close.
    c.read(active.notifier).state = [
      Session(
        id: 's1',
        projectId: 'p1',
        agent: 'pi',
        title: 'session s1',
        status: SessionStatus.running,
        policy: ApprovalPolicy.askOnRisky,
      ),
    ];
    await tester.pumpAndSettle();

    expect(store.loads, 1);
  });

  testWidgets('pull-to-refresh keeps its spinner until the reload lands', (
    tester,
  ) async {
    late _FakeStore store;
    final c = container((ref) => store = _FakeStore(ref));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: ClosedScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Hold the next load open, then pull.
    store.gate = Completer<List<Session>>();
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(RefreshProgressIndicator),
      findsOneWidget,
      reason: 'spinner must stay while the reload is in flight',
    );

    store.gate!.complete([_session('a1', closed: true)]);
    await tester.pumpAndSettle();

    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });
}
