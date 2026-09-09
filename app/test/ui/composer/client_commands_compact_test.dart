// Behavioural tests for the `/compact` and `/autocompact` client commands.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/status/status_center.dart';
import 'package:makit/status/status_providers.dart';
import 'package:makit/ui/composer/client_commands.dart';

const _kMeta = SessionMeta(thinking: '', models: []);

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// Records control actions `/compact` and `/autocompact` forward.
class _FakeStore extends StoreController {
  _FakeStore(super.ref);

  final List<({String sessionId, String action, Map<String, dynamic>? args})>
  actions = [];

  @override
  void sendSessionAction(
    String sessionId,
    String action, {
    Map<String, dynamic>? args,
  }) {
    actions.add((sessionId: sessionId, action: action, args: args));
  }
}

Session _session() => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Current session',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  worktreePath: '/tmp/wt/feat',
  branch: 'feat/compact',
);

Future<_FakeStore> _runCommand(
  WidgetTester tester,
  String command, {
  StatusCenter? status,
}) async {
  late _FakeStore store;
  final session = _session();
  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
      sessionsProvider.overrideWithValue(SessionsState([session])),
      storeControllerProvider.overrideWith((ref) {
        store = _FakeStore(ref);
        return store;
      }),
      sessionMetaProvider.overrideWith((ref, sessionId) => _kMeta),
      if (status != null) statusCenterProvider.overrideWithValue(status),
    ],
  );
  addTearDown(container.dispose);
  container.read(storeControllerProvider.notifier);

  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Consumer(
          builder: (ctx, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => handleClientCommand(
                command,
                context: ctx,
                ref: ref,
                sessionId: session.id,
              ),
              child: const Text('run'),
            ),
          ),
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.tap(find.text('run'));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('/compact forwards instructions as args', (tester) async {
    final store = await _runCommand(tester, '/compact keep the plan');

    expect(store.actions.length, 1);
    expect(store.actions.first.sessionId, 's1');
    expect(store.actions.first.action, 'compact');
    expect(store.actions.first.args, {'instructions': 'keep the plan'});
  });

  testWidgets('/compact omits args when there are no instructions', (
    tester,
  ) async {
    final store = await _runCommand(tester, '/compact');

    expect(store.actions.length, 1);
    expect(store.actions.first.sessionId, 's1');
    expect(store.actions.first.action, 'compact');
    expect(store.actions.first.args, isNull);
  });

  testWidgets('/autocompact defaults to toggle', (tester) async {
    final store = await _runCommand(tester, '/autocompact');

    expect(store.actions.length, 1);
    expect(store.actions.first.sessionId, 's1');
    expect(store.actions.first.action, 'autocompact');
    expect(store.actions.first.args, {'mode': 'toggle'});
  });

  testWidgets('/autocompact accepts on and off', (tester) async {
    for (final mode in ['on', 'off', 'toggle']) {
      final store = await _runCommand(tester, '/autocompact $mode');
      expect(store.actions.length, 1);
      expect(store.actions.first.sessionId, 's1');
      expect(store.actions.first.action, 'autocompact');
      expect(store.actions.first.args, {'mode': mode});
    }
  });

  testWidgets('/autocompact warns on unknown mode and sends nothing', (
    tester,
  ) async {
    final center = StatusCenter();
    addTearDown(center.dispose);
    final store = await _runCommand(tester, '/autocompact onn', status: center);

    expect(store.actions, isEmpty);
    expect(center.events.single.title, contains('Unknown autocompact mode'));
  });
}
