import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

class _EmptyStorage extends FlutterSecureStorage {
  const _EmptyStorage() : super();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => null;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}

Future<void> _pumpPane(WidgetTester tester, {required String sessionId}) async {
  final session = Session(
    id: sessionId,
    projectId: 'p1',
    agent: 'pi',
    title: 'Session',
    status: SessionStatus.idle,
    policy: ApprovalPolicy.askOnRisky,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectionControllerProvider.overrideWith(
          (ref) => ConnectionController(const _EmptyStorage()),
        ),
        selectedSessionProvider.overrideWith((ref) => sessionId),
        sessionsProvider.overrideWithValue(SessionsState([session])),
        reposProvider.overrideWithValue(ReposState(const [])),
        chatItemsProvider(sessionId).overrideWithValue(const []),
        sessionActionErrorProvider(sessionId).overrideWithValue(null),
        commandsProvider(sessionId).overrideWithValue(const []),
      ],
      child: const MaterialApp(home: Scaffold(body: DesktopChatPane())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('actions menu exposes the same items as the mobile screen', (
    tester,
  ) async {
    await _pumpPane(tester, sessionId: 's1');

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();

    expect(find.text('Rename session'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('Quit session'), findsOneWidget);
  });

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
}
