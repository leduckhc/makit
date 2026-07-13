import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

void main() {
  testWidgets('shows empty state when no session is selected', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: DesktopChatPane())),
      ),
    );

    expect(find.text('Select or start a session'), findsOneWidget);
  });

  testWidgets('shows transcript header when a session is selected', (
    tester,
  ) async {
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'Test session',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
      lastPreview: '',
      lastActivityAt: 0,
    );

    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWithValue(SessionsState([session])),
        eventsProvider.overrideWithValue(EventsState(const {}, const {})),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedSessionProvider.notifier).state = 's1';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DesktopChatPane())),
      ),
    );
    await tester.pump();

    expect(find.text('Test session'), findsOneWidget);
    expect(find.text('Send a message to start.'), findsOneWidget);
  });
}
