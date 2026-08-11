// Review follow-up on PR #157: the desktop closed-sidebar's live-sync listener
// had no baseline, so the FIRST close/reopen elsewhere was swallowed and the
// list stayed stale until the user toggled the view. The mobile ClosedScreen
// already seeded its baseline (and has `closed_screen_sync_test.dart`); this is
// the same guarantee for the desktop surface.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/desktop/chat/closed_sidebar_view.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';

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

/// Counts closed-list loads.
class _FakeStore extends StoreController {
  _FakeStore(super.ref);

  int loads = 0;

  @override
  Future<List<Session>> listClosedSessions() {
    loads++;
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
        sidebarClosedProvider.overrideWith((_) => true),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<_FakeStore> pump(WidgetTester tester) async {
    late _FakeStore store;
    final c = container((ref) => store = _FakeStore(ref));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 320, child: ClosedSidebarView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('reloads on the first close that happens elsewhere', (
    tester,
  ) async {
    final store = await pump(tester);
    expect(store.loads, 1, reason: 'initial load');

    // Somebody closes s1 from a chat pane: the active set loses an id.
    tester.element(find.byType(ClosedSidebarView));
    final c = ProviderScope.containerOf(
      tester.element(find.byType(ClosedSidebarView)),
    );
    c.read(active.notifier).state = const [];
    await tester.pumpAndSettle();

    expect(
      store.loads,
      2,
      reason: 'the very first change must reload, not just record a baseline',
    );
  });

  testWidgets('ignores churn that does not change the id set', (tester) async {
    final store = await pump(tester);
    final c = ProviderScope.containerOf(
      tester.element(find.byType(ClosedSidebarView)),
    );

    // Same id, new status — routine activity, not a close/reopen.
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

    expect(store.loads, 1, reason: 'status churn must not refetch');
  });
}
