import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/repo_chips.dart';

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

  testWidgets('slim header: no branch chip, status chip, or agent subtitle', (
    tester,
  ) async {
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'Test session',
      status: SessionStatus.running,
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

    expect(find.byType(BranchChip), findsNothing);
    expect(find.byType(SessionStatusChip), findsNothing);
    expect(find.text('pi'), findsNothing); // agent subtitle removed
  });

  testWidgets('unfold button appears only while the sidebar is collapsed', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => null,
        );
    final container = ProviderContainer(
      overrides: [sidebarCollapsedProvider.overrideWith((ref) => true)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: DesktopChatPane())),
      ),
    );

    // Reachable even with no session selected (empty state).
    expect(find.byTooltip('Show sidebar'), findsOneWidget);

    await tester.tap(find.byTooltip('Show sidebar'));
    await tester.pump();
    expect(container.read(sidebarCollapsedProvider), isFalse);
    expect(find.byTooltip('Show sidebar'), findsNothing);
  });

  testWidgets('slim header: no draft tag for a pending session', (
    tester,
  ) async {
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: 'Test session',
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
      pending: true,
      lastPreview: '',
      lastActivityAt: 0,
    );

    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWithValue(SessionsState([session])),
        eventsProvider.overrideWithValue(EventsState(const {}, const {})),
        // Pending sessions now show the harness picker, which reads the agent
        // list; stub it so the widget test doesn't hit the network.
        agentsProvider.overrideWith((ref) => const <AgentDescriptor>[]),
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

    // The header used to show a `draft` TagChip for pending sessions; that
    // moved to the sidebar tile only.
    expect(find.byType(TagChip), findsNothing);
    expect(find.text('draft'), findsNothing);
  });

  testWidgets('header falls back to the agent name when the title is blank', (
    tester,
  ) async {
    final session = Session(
      id: 's1',
      projectId: 'p1',
      agent: 'pi',
      title: '   ',
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

    // Decision 8: blank title falls back to the agent name, not the id.
    expect(find.text('pi'), findsOneWidget);
    expect(find.text('s1'), findsNothing);
  });

  testWidgets(
    'session actions menu offers Rename + Quit only (no model/thinking)',
    (tester) async {
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

      await tester.tap(find.byTooltip('Session actions'));
      await tester.pumpAndSettle();

      // Model + thinking moved into the composer footer; the overflow menu keeps
      // only rename + quit.
      expect(find.text('Rename session'), findsOneWidget);
      expect(find.text('Quit session'), findsOneWidget);
      expect(find.text('Model'), findsNothing);
      expect(find.text('Thinking'), findsNothing);
    },
  );

  testWidgets(
    'unfold button and title coexist when collapsed with a session selected',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => null,
          );
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
          sidebarCollapsedProvider.overrideWith((ref) => true),
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

      expect(find.byTooltip('Show sidebar'), findsOneWidget);
      expect(find.text('Test session'), findsOneWidget);

      await tester.tap(find.byTooltip('Show sidebar'));
      await tester.pump();
      expect(container.read(sidebarCollapsedProvider), isFalse);
    },
  );
}
