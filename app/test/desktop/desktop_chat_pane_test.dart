import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/repo_chips.dart';
import 'package:makit/ui/session/tool_renderers.dart'
    show kReadableContentMaxWidth;

Session _session() => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Test session',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
);

ProviderContainer _thinkingContainer(String text) {
  final container = ProviderContainer(
    overrides: [
      sessionsProvider.overrideWithValue(SessionsState([_session()])),
      eventsProvider.overrideWithValue(EventsState(const {}, const {})),
      chatItemsProvider(
        's1',
      ).overrideWithValue([ThinkingItem(seq: 1, ts: 0, text: text)]),
    ],
  );
  container.read(selectedSessionProvider.notifier).state = 's1';
  return container;
}

void main() {
  group('_ThinkingLine interaction', () {
    const thinking = 'Reasoning about the answer in detail';

    Future<void> pumpThinking(WidgetTester tester) async {
      final container = _thinkingContainer(thinking);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('collapsed by default: plain Text, no SelectableText', (
      tester,
    ) async {
      await pumpThinking(tester);

      expect(find.byType(SelectableText), findsNothing);
      final textWidget = tester.widget<Text>(find.text(thinking));
      expect(textWidget.maxLines, 1);
      expect(textWidget.overflow, TextOverflow.ellipsis);
    });

    testWidgets('tapping the collapsed row expands to a SelectableText', (
      tester,
    ) async {
      await pumpThinking(tester);

      await tester.tap(find.text(thinking));
      await tester.pump();

      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('expanded exposes a "Collapse thinking" semantics action', (
      tester,
    ) async {
      await pumpThinking(tester);
      await tester.tap(find.text(thinking));
      await tester.pump();

      final semantics = tester.widgetList<Semantics>(find.byType(Semantics));
      expect(
        semantics.any(
          (s) => s.properties.hintOverrides?.onTapHint == 'Collapse thinking',
        ),
        isTrue,
      );
    });

    testWidgets('tapping the leading icon while expanded collapses', (
      tester,
    ) async {
      await pumpThinking(tester);
      await tester.tap(find.text(thinking));
      await tester.pump();
      expect(find.byType(SelectableText), findsOneWidget);

      await tester.tap(find.byIcon(Symbols.psychology));
      await tester.pump();

      expect(find.byType(SelectableText), findsNothing);
    });
  });

  testWidgets('shows empty state when no session is selected', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
        ),
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
        child: const MaterialApp(
          home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
        ),
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
        child: const MaterialApp(
          home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
        ),
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
        child: const MaterialApp(
          home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
        ),
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
        child: const MaterialApp(
          home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
        ),
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
        child: const MaterialApp(
          home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
        ),
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
          child: const MaterialApp(
            home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
          ),
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
    'transcript ListView fills the full pane width so scrolling works anywhere',
    (tester) async {
      // A wide pane: full-width ListView should be wider than the readable cap,
      // proving the scroll/hit area is not limited to the centered column.
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState([_session()])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
          chatItemsProvider(
            's1',
          ).overrideWithValue([UserMessageItem(seq: 1, ts: 0, text: 'hi')]),
        ],
      );
      addTearDown(container.dispose);
      container.read(selectedSessionProvider.notifier).state = 's1';

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
          ),
        ),
      );
      await tester.pump();

      final listWidth = tester.getSize(find.byType(ListView)).width;
      expect(listWidth, 1200);
      expect(listWidth, greaterThan(kReadableContentMaxWidth));
    },
  );

  testWidgets('composer draft survives the pane being disposed and recreated', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWithValue(SessionsState([_session()])),
        eventsProvider.overrideWithValue(EventsState(const {}, const {})),
      ],
    );
    addTearDown(container.dispose);
    container.read(selectedSessionProvider.notifier).state = 's1';

    Widget app(Widget child) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    );

    await tester.pumpWidget(app(const DesktopChatPane(sessionId: 's1')));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'unsent draft');
    await tester.pumpAndSettle();

    // Dispose the pane (as a worktree switch or pane split would).
    await tester.pumpWidget(app(const SizedBox.shrink()));
    await tester.pump();

    // Recreate it — the draft must come back.
    await tester.pumpWidget(app(const DesktopChatPane(sessionId: 's1')));
    await tester.pump();

    expect(find.text('unsent draft'), findsOneWidget);
  });
}
