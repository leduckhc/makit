// Mobile closed-sessions view (SPEC-29): lists the closed sessions the
// server holds, grouped by repo, and restores one back to the active list.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Serves a fixed closed list and records restores.
class _FakeStore extends StoreController {
  _FakeStore(super.ref, this.closed, {this.throws = false});

  final List<Session> closed;
  final bool throws;
  final List<String> restored = [];
  int loadCount = 0;

  @override
  Future<List<Session>> listClosedSessions() async {
    loadCount++;
    // The real store awaits a server round-trip; yield so a failure reaches the
    // FutureBuilder as a future error rather than before it can subscribe.
    await Future<void>.delayed(Duration.zero);
    if (throws) throw StateError('offline');
    return closed;
  }

  @override
  Future<void> reopenSession(String id) async {
    restored.add(id);
  }
}

Session _session(
  String id, {
  String projectId = 'p1',
  String agent = 'pi',
  String? branch = 'feature',
  bool orphaned = false,
}) => Session(
  id: id,
  projectId: projectId,
  agent: agent,
  title: 'sess-$id',
  status: SessionStatus.exited,
  policy: ApprovalPolicy.askOnRisky,
  branch: branch,
  resumable: true,
  closed: true,
  orphaned: orphaned,
);

Future<_FakeStore> _pump(
  WidgetTester tester,
  List<Session> closed, {
  bool throws = false,
}) async {
  late _FakeStore store;
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      storeControllerProvider.overrideWith((ref) {
        store = _FakeStore(ref, closed, throws: throws);
        return store;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(storeControllerProvider.notifier);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ClosedScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('lists closed sessions', (tester) async {
    await _pump(tester, [_session('a'), _session('b')]);

    expect(find.text('sess-a'), findsOneWidget);
    expect(find.text('sess-b'), findsOneWidget);
  });

  testWidgets('shows an empty state when nothing is closed', (tester) async {
    await _pump(tester, const []);

    expect(find.text('No closed sessions.'), findsOneWidget);
  });

  testWidgets('shows a retryable error when the load fails', (tester) async {
    final store = await _pump(tester, const [], throws: true);
    expect(store.loadCount, 1);

    expect(find.textContaining("Couldn't load"), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(store.loadCount, 2);
    // (The failure is surfaced in the UI, not as an unhandled async error.)
    expect(find.textContaining("Couldn't load"), findsOneWidget);
  });

  testWidgets('restores a session and reloads the list', (tester) async {
    final store = await _pump(tester, [_session('a')]);
    expect(store.loadCount, 1);

    await tester.tap(find.widgetWithText(TextButton, 'Reopen'));
    await tester.pumpAndSettle();

    expect(store.restored, ['a']);
    // Reloaded so the restored row leaves the closed list.
    expect(store.loadCount, 2);
  });

  testWidgets('flags a session whose worktree was removed', (tester) async {
    await _pump(tester, [_session('a', orphaned: true)]);

    expect(find.text('worktree removed'), findsOneWidget);
  });
}
