import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/store/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/chat_transcript.dart';
import 'package:makit/ui/session/session_screen.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();

  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
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

  Future<void> pumpScreen(
    WidgetTester tester, {
    required List<ChatItem> items,
    required SessionStatus status,
  }) async {
    const sessionId = 's1';
    final session = Session(
      id: sessionId,
      projectId: 'p1',
      agent: 'pi',
      title: 'Session',
      status: status,
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
          chatItemsProvider(sessionId).overrideWithValue(items),
          sessionMetaProvider(sessionId).overrideWithValue(null),
          sessionActionErrorProvider(sessionId).overrideWithValue(null),
          commandsProvider(sessionId).overrideWithValue(const []),
        ],
        child: const MaterialApp(home: SessionScreen(sessionId: sessionId)),
      ),
    );
    await tester.pump();
  }

  testWidgets('reversed transcript renders oldest at top, newest at bottom', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      status: SessionStatus.idle,
      items: [
        UserMessageItem(seq: 1, ts: 0, text: 'oldest'),
        AgentMessageItem(seq: 2, ts: 0, text: 'newest'),
      ],
    );

    // Visual order is unchanged (oldest higher on screen than newest),
    // even though the underlying ListView is reversed.
    final oldestY = tester.getTopLeft(find.text('oldest')).dy;
    final newestY = tester.getTopLeft(find.text('newest')).dy;
    expect(oldestY, lessThan(newestY));
  });

  testWidgets('working indicator sits below the newest message when running', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      status: SessionStatus.running,
      items: [AgentMessageItem(seq: 1, ts: 0, text: 'newest')],
    );

    final newestY = tester.getTopLeft(find.text('newest')).dy;
    final indicatorY = tester.getTopLeft(find.byType(WorkingIndicator)).dy;
    expect(indicatorY, greaterThan(newestY));
  });
}
