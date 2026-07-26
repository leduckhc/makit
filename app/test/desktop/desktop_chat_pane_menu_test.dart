import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/store/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();

  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

class _ControllableConnection extends ConnectionController {
  _ControllableConnection() : super(const _EmptyStorage());

  final killCompleted = Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> request(
    MsgType type,
    Map<String, dynamic> body,
  ) {
    if (body['kind'] == 'session.kill') return killCompleted.future;
    return Future.value(const {});
  }
}

Future<ProviderContainer> _pumpPane(
  WidgetTester tester, {
  required String sessionId,
  ConnectionController? connection,
}) async {
  final session = Session(
    id: sessionId,
    projectId: 'p1',
    agent: 'pi',
    title: 'Session',
    status: SessionStatus.idle,
    policy: ApprovalPolicy.askOnRisky,
  );

  final container = ProviderContainer(
    overrides: [
      connectionControllerProvider.overrideWith(
        (ref) => connection ?? ConnectionController(const _EmptyStorage()),
      ),
      sessionsProvider.overrideWithValue(SessionsState([session])),
      reposProvider.overrideWithValue(ReposState(const [])),
      chatItemsProvider(sessionId).overrideWithValue(const []),
      sessionActionErrorProvider(sessionId).overrideWithValue(null),
      commandsProvider(sessionId).overrideWithValue(const []),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: DesktopChatPane(sessionId: sessionId)),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets(
    'actions menu exposes rename + quit (model/thinking moved to composer)',
    (tester) async {
      await _pumpPane(tester, sessionId: 's1');

      await tester.tap(find.byTooltip('Session actions'));
      await tester.pumpAndSettle();

      expect(find.text('Rename session'), findsOneWidget);
      expect(find.text('Quit session'), findsOneWidget);
      // Model + thinking-effort now live inline in the composer footer.
      expect(find.text('Model'), findsNothing);
      expect(find.text('Thinking'), findsNothing);
    },
  );

  testWidgets('Quit prompts for confirmation before killing the session', (
    tester,
  ) async {
    await _pumpPane(tester, sessionId: 's1');

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit session'));
    await tester.pumpAndSettle();

    expect(find.text('Quit session?'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Quit'), findsOneWidget);
  });

  testWidgets('Quit completion preserves a newer session selection', (
    tester,
  ) async {
    final connection = _ControllableConnection();
    final container = await _pumpPane(
      tester,
      sessionId: 's1',
      connection: connection,
    );
    // s1 is the visible/selected session (its tab is active in the workspace).
    container.read(workspaceControllerProvider.notifier).revealSession('s1');
    await tester.pump();
    expect(container.read(selectedSessionProvider), 's1');

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit session'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Quit'));
    await tester.pump();

    // The user moves on to a newer session while the kill is still in flight.
    container.read(workspaceControllerProvider.notifier).revealSession('s2');
    await tester.pump();

    connection.killCompleted.complete(const {});
    await tester.pump();

    // Quit never writes the selection (it is derived from the active tab), so
    // the background kill completion cannot stomp the newer selection.
    expect(container.read(selectedSessionProvider), 's2');
  });
}
