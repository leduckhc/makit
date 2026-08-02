import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/desktop/chat/groups/agent_picker.dart';
import 'package:makit/desktop/chat/pr_bar.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/groups/group.dart';
import 'package:makit/desktop/chat/groups/groups_controller.dart';
import 'package:makit/desktop/chat/harness_picker.dart' show HarnessCard;
import 'package:makit/desktop/chat/worktree_starter.dart';
import 'package:makit/ui/composer/composer_draft.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/sidebar_layout.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer_selectors.dart' show ThinkingSignal;
import 'package:makit/ui/composer/model_picker_menu.dart'
    show kModelFlyoutCaretIcon;
import 'package:makit/ui/home/repo_chips.dart';
import 'package:makit/ui/session/transcript_list.dart';
import 'package:makit/ui/session/tool_renderers.dart'
    show kReadableContentMaxWidth;

const _wtA = SelectedWorktree(projectId: 'p1', path: '/tmp/wt-a', branch: 'a');

/// In-memory secure storage so ConnectionController boots without platform
/// channels.
class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

/// Records what the in-pane starter spawns/sends so the tests can assert it.
class _StarterStore extends StoreController {
  _StarterStore(super.ref);

  int spawnCount = 0;
  String? spawnAgent;
  String? spawnWorktreePath;
  String? spawnBranch;
  List<ConfigOptionPick>? spawnPicks;
  final List<String> sent = [];

  /// When true, `spawnSession` throws — to exercise the starter's error path.
  bool spawnThrows = false;

  @override
  Future<String> spawnSession(
    String projectId, {
    String? title,
    String? agent,
    String? worktreePath,
    String? branch,
    List<ConfigOptionPick>? configOptions,
  }) async {
    spawnCount++;
    spawnAgent = agent;
    spawnWorktreePath = worktreePath;
    spawnBranch = branch;
    spawnPicks = configOptions;
    if (spawnThrows) throw StateError('spawn failed');
    return 'spawned';
  }

  @override
  void appendOptimisticMessage(String sessionId, String text) {}

  @override
  void sendMessage(String sessionId, String text, {List<String>? mediaPaths}) {
    sent.add(text);
  }
}

/// A harness advertising a model + reasoning-effort catalog (what the pills
/// render from before any session exists).
AgentDescriptor _codex() => const AgentDescriptor(
  id: 'codex',
  label: 'Codex',
  transport: 'native',
  available: true,
  configOptions: [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      type: ConfigOptionType.select,
      currentValue: 'gpt-5',
      options: [
        ConfigOptionValue(value: 'gpt-5', name: 'GPT-5'),
        ConfigOptionValue(value: 'gpt-5-codex', name: 'GPT-5 Codex'),
      ],
    ),
    SessionConfigOption(
      id: 'effort',
      name: 'Reasoning effort',
      category: 'thought_level',
      type: ConfigOptionType.select,
      currentValue: 'medium',
      options: [
        ConfigOptionValue(value: 'medium', name: 'Medium'),
        ConfigOptionValue(value: 'high', name: 'High'),
      ],
    ),
  ],
);

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

      await tester.tap(find.byIcon(PhosphorIconsLight.brain));
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

    expect(find.text('Select a session, or start a new one'), findsOneWidget);
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
      ],
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
    'session actions menu offers Rename + Archive only (no model/thinking)',
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
      expect(find.text('Archive session'), findsOneWidget);
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

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: DesktopChatPane(sessionId: 's1')),
          ),
        ),
      );
      await tester.pump();

      final listWidth = tester.getSize(find.byType(TranscriptListView)).width;
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

  testWidgets(
    'composer draft does not leak across an in-place session switch',
    (tester) async {
      final s2 = Session(
        id: 's2',
        projectId: 'p1',
        agent: 'pi',
        title: 'Second session',
        status: SessionStatus.idle,
        policy: ApprovalPolicy.askOnRisky,
        lastPreview: '',
        lastActivityAt: 0,
      );
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState([_session(), s2])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
        ],
      );
      addTearDown(container.dispose);

      Widget app(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: Scaffold(body: child)),
      );

      // Same pane state, rebind s1 -> s2 in place (as selecting another session
      // in the active leaf does).
      await tester.pumpWidget(app(const DesktopChatPane(sessionId: 's1')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 's1 draft');
      await tester.pumpAndSettle();

      await tester.pumpWidget(app(const DesktopChatPane(sessionId: 's2')));
      await tester.pump();

      // s2 starts blank: s1's text must not bleed in, and s1's draft is intact.
      expect(find.text('s1 draft'), findsNothing);
      expect(container.read(composerDraftsProvider)['s1'], 's1 draft');
      expect(container.read(composerDraftsProvider)['s2'], isNull);
    },
  );

  group('null/dead-session worktree fallback', () {
    Future<ProviderContainer> pumpPane(
      WidgetTester tester, {
      String? sessionId,
      SelectedWorktree? worktree,
    }) async {
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(const [])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
          agentsProvider.overrideWith((ref) async => const <AgentDescriptor>[]),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: DesktopChatPane(sessionId: sessionId, worktree: worktree),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('a real worktree with no session starts in place', (
      tester,
    ) async {
      await pumpPane(tester, worktree: _wtA);

      final starter = tester.widget<WorktreeStarter>(
        find.byType(WorktreeStarter),
      );
      expect(starter.worktree, _wtA);
      expect(find.byType(EmptyPaneStarter), findsNothing);
    });

    testWidgets(
      'a real worktree with a dead (persisted, now-missing) session id '
      'also starts in place',
      (tester) async {
        await pumpPane(tester, sessionId: 'dead-session', worktree: _wtA);

        final starter = tester.widget<WorktreeStarter>(
          find.byType(WorktreeStarter),
        );
        expect(starter.worktree, _wtA);
      },
    );
  });

  group('in-pane starter (harness picker page)', () {
    Future<_StarterStore> pumpStarter(
      WidgetTester tester, {
      SelectedWorktree? worktree,
      List<AgentDescriptor> agents = const [],
    }) async {
      late _StarterStore store;
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          // StoreController's constructor subscribes to the connection and
          // sends `hello`; without this override the test reaches the real one.
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          sessionsProvider.overrideWithValue(SessionsState(const [])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
          agentsProvider.overrideWith((ref) async => agents),
          storeControllerProvider.overrideWith((ref) {
            store = _StarterStore(ref);
            return store;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(storeControllerProvider.notifier);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: DesktopChatPane(worktree: worktree)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return store;
    }

    testWidgets('a pane with a worktree shows harness cards + model pill '
        '(reasoning folded) + a composer', (tester) async {
      await pumpStarter(tester, worktree: _wtA, agents: [_codex()]);

      expect(find.byType(HarnessCard), findsOneWidget);
      // The selected harness's catalog drives the composer pills before any
      // session exists. Reasoning (thought_level) folds into the model pill as
      // a read-only signal-bar chip (SPEC-31) rather than a standalone pill.
      expect(find.text('GPT-5'), findsOneWidget);
      expect(find.byType(ThinkingSignal), findsOneWidget);
      expect(find.text('Medium'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('sending the first message spawns in the pane worktree with '
        'the chosen picks', (tester) async {
      final store = await pumpStarter(
        tester,
        worktree: _wtA,
        agents: [_codex()],
      );

      // Tune reasoning to High via the model picker flyout, then send.
      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(kModelFlyoutCaretIcon));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High').last);
      await tester.pumpAndSettle();
      // Dismiss the picker sheet (tap the modal barrier above it).
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'start here');
      await tester.pump();
      await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp).last);
      await tester.pumpAndSettle();

      expect(store.spawnCount, 1);
      expect(store.spawnAgent, 'codex');
      expect(store.spawnWorktreePath, '/tmp/wt-a');
      expect(store.spawnBranch, 'a');
      expect(store.spawnPicks!.single.id, 'effort');
      expect(store.spawnPicks!.single.value, 'high');
      expect(store.sent, ['start here']);
    });

    testWidgets('carries the PR bar, like a live session\'s composer', (
      tester,
    ) async {
      // A fresh worktree is not a second-class pane: the PR status pill and the
      // "most actionable next step" split button that sit above a live
      // session's composer belong here too.
      await pumpStarter(tester, worktree: _wtA, agents: [_codex()]);

      expect(find.byType(PrComposerBar), findsOneWidget);
      final bar = tester.widget<PrComposerBar>(find.byType(PrComposerBar));
      expect(
        bar.pr,
        isNull,
        reason:
            'no repo snapshot in this test, so no PR — but the bar is there',
      );
    });

    testWidgets('no available harnesses falls back to the host default hint', (
      tester,
    ) async {
      await pumpStarter(tester, worktree: _wtA);

      expect(find.byType(HarnessCard), findsNothing);
      expect(find.text('Using the host default harness.'), findsOneWidget);
      // Still startable: the server picks its default harness.
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('preselects the first AVAILABLE harness, skipping unavailable '
        'ones', (tester) async {
      const unavailable = AgentDescriptor(
        id: 'down',
        label: 'Down',
        transport: 'acp',
        available: false,
      );
      await pumpStarter(
        tester,
        worktree: _wtA,
        agents: [unavailable, _codex()],
      );

      // Codex (the first *available*) is the selected card, not the unavailable
      // first entry.
      final cards = tester.widgetList<HarnessCard>(find.byType(HarnessCard));
      final selected = cards.where((c) => c.selected).toList();
      expect(selected.length, 1);
      expect(selected.single.agent.id, 'codex');
    });

    testWidgets('surfaces an error and re-enables when the spawn fails', (
      tester,
    ) async {
      final store = await pumpStarter(
        tester,
        worktree: _wtA,
        agents: [_codex()],
      );
      store.spawnThrows = true;

      await tester.enterText(find.byType(TextField), 'go');
      await tester.pump();
      await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp).last);
      await tester.pumpAndSettle();

      expect(store.spawnCount, 1);
      expect(find.textContaining('spawn failed'), findsOneWidget);
      // Re-enabled: the composer's send affordance is back (not stuck spinning).
      expect(find.byIcon(PhosphorIconsLight.arrowUp), findsWidgets);
    });

    testWidgets('switching harness clears the pending config picks', (
      tester,
    ) async {
      // A second harness that also has an effort catalog, so the pill exists on
      // both — the point is the *pick* made on the first must not ride along.
      const codex2 = AgentDescriptor(
        id: 'codex2',
        label: 'Codex 2',
        transport: 'native',
        available: true,
        configOptions: [
          SessionConfigOption(
            id: 'effort',
            name: 'Reasoning effort',
            category: 'thought_level',
            type: ConfigOptionType.select,
            currentValue: 'medium',
            options: [
              ConfigOptionValue(value: 'medium', name: 'Medium'),
              ConfigOptionValue(value: 'high', name: 'High'),
            ],
          ),
        ],
      );
      final store = await pumpStarter(
        tester,
        worktree: _wtA,
        agents: [_codex(), codex2],
      );

      // Pick High on the (default) codex harness via the model picker flyout…
      await tester.tap(find.text('GPT-5'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(kModelFlyoutCaretIcon));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High').last);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      // …then switch to codex2 and send.
      await tester.tap(find.text('Codex 2'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'go');
      await tester.pump();
      await tester.tap(find.byIcon(PhosphorIconsLight.arrowUp).last);
      await tester.pumpAndSettle();

      expect(store.spawnAgent, 'codex2');
      expect(
        store.spawnPicks,
        anyOf(isNull, isEmpty),
        reason: 'the High pick belonged to codex and must not carry over',
      );
    });

    testWidgets('an empty BOARD also offers Add agent (decision 14 path a)', (
      tester,
    ) async {
      // A board has no branch, so "New session" alone is not enough: the other
      // thing you want on an empty board is to pull in an agent that is already
      // running. The tab-strip + covers a non-empty board; this covers the
      // empty one, which has no tab strip to speak of.
      late _StarterStore store;
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(const [])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
          agentsProvider.overrideWith((ref) async => const <AgentDescriptor>[]),
          groupsControllerProvider.overrideWith(
            (ref) => GroupsController.ephemeral(
              GroupsState(
                groups: [
                  Group.board(
                    id: 'b1',
                    label: 'Board 1',
                    tree: WorkspaceController.seedWorkspace(),
                  ),
                ],
                activeGroupId: 'b1',
              ),
            ),
          ),
          storeControllerProvider.overrideWith((ref) {
            store = _StarterStore(ref);
            return store;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(storeControllerProvider.notifier);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: DesktopChatPane())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Select a session, or start a new one'), findsOneWidget);
      expect(find.text('New worktree'), findsOneWidget);
      expect(find.text('Add agent'), findsOneWidget);

      await tester.tap(find.text('Add agent'));
      await tester.pumpAndSettle();
      expect(find.byType(AgentPicker), findsOneWidget);
      expect(store.spawnCount, 0, reason: 'adding is not spawning');
    });

    testWidgets('a worktree group\'s empty pane does NOT offer Add agent', (
      tester,
    ) async {
      // Membership there is derived — there is no list to add to.
      await pumpStarter(tester, worktree: _wtA, agents: [_codex()]);
      expect(find.text('Add agent'), findsNothing);
    });

    testWidgets('a pane with NO worktree keeps the New worktree button', (
      tester,
    ) async {
      await pumpStarter(tester, agents: [_codex()]);

      expect(find.byType(HarnessCard), findsNothing);
      expect(find.text('New worktree'), findsOneWidget);
    });
  });

  group('reversed transcript auto-scroll', () {
    // A tall transcript so the reversed list overflows and can be scrolled up.
    List<ChatItem> longTranscript() => [
      for (var i = 1; i <= 40; i++)
        UserMessageItem(seq: i, ts: 0, text: 'message #$i'),
    ];

    Future<(ScrollController, void Function(List<ChatItem>))> pumpStreaming(
      WidgetTester tester, {
      required List<ChatItem> initial,
    }) async {
      final itemsController = StateProvider<List<ChatItem>>((ref) => initial);
      final container = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState([_session()])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
          chatItemsProvider(
            's1',
          ).overrideWith((ref) => ref.watch(itemsController)),
        ],
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
      await tester.pump();
      final controller = tester
          .widget<TranscriptListView>(find.byType(TranscriptListView))
          .controller;
      void push(List<ChatItem> next) =>
          container.read(itemsController.notifier).state = next;
      return (controller, push);
    }

    testWidgets(
      'a streamed message while scrolled up does not yank to newest',
      (tester) async {
        final items = longTranscript();
        final (controller, push) = await pumpStreaming(tester, initial: items);

        expect(controller.position.maxScrollExtent, greaterThan(120));
        controller.jumpTo(300);
        await tester.pump();

        push([...items, AgentMessageItem(seq: 999, ts: 0, text: 'incoming')]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.position.pixels, greaterThan(120));
      },
    );

    testWidgets(
      'a streamed message while near the bottom pulls to the newest',
      (tester) async {
        final items = longTranscript();
        final (controller, push) = await pumpStreaming(tester, initial: items);

        controller.jumpTo(50);
        await tester.pump();

        push([...items, AgentMessageItem(seq: 999, ts: 0, text: 'incoming')]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(controller.position.pixels, lessThanOrEqualTo(1.0));
      },
    );
  });
}
