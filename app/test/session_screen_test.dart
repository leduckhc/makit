import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/session_screen.dart';

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

void main() {
  testWidgets('expanded thinking can be collapsed through semantics', (
    tester,
  ) async {
    const sessionId = 's1';
    const thinking = 'A detailed reasoning trace';
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
          projectsProvider.overrideWithValue(ProjectsState(const [])),
          sessionsProvider.overrideWithValue(SessionsState([session])),
          chatItemsProvider(
            sessionId,
          ).overrideWithValue([ThinkingItem(seq: 1, ts: 0, text: thinking)]),
          sessionMetaProvider(sessionId).overrideWithValue(null),
          sessionActionErrorProvider(sessionId).overrideWithValue(null),
          commandsProvider(sessionId).overrideWithValue(const []),
        ],
        child: const MaterialApp(home: SessionScreen(sessionId: sessionId)),
      ),
    );
    await tester.pump();

    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text(thinking));
    await tester.pump();

    final semantics = tester.getSemantics(find.byType(SelectableText));
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    semantics.owner!.performAction(semantics.id, SemanticsAction.tap);
    await tester.pump();

    expect(find.byType(SelectableText), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
  });
}
