// SPEC-51 C2c — the two panel DOORS (D13) and the tab menu's Copy session id
// (D6). The desktop tab menu deliberately does NOT get a *Session details* item
// — a third door onto the same sheet, one pixel from the pane kebab on the same
// platform, was cut on review; Copy session id is a different job.
//
// The MUTATION guard here is the tab menu's bare-id assertion: pointing Copy
// session id at `sessionIdentityText` (the whole label:value payload) instead
// of the bare id must fail `clipboard.writes == [kAgentId]`.
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/split_tree_view.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/session/session_identity.dart';
import 'package:makit/ui/session/session_screen.dart';

const kAgentId = '019fa9f4-443d-7d86-8f4c-d9c4988ddf4f';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

Session _session(
  String id,
  String title, {
  String? agentSessionId = kAgentId,
}) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: title,
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
  worktreePath: '/tmp/wt-a',
  branch: 'feat/x',
  agentSessionId: agentSessionId,
);

class _Clipboard {
  final List<String> writes = [];
  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
  }

  void remove(WidgetTester tester) => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}

void main() {
  // ── mobile glass menu (session_screen) ────────────────────────────────────
  group('C2c — mobile glass menu door', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionControllerProvider.overrideWith(
              (ref) => ConnectionController(const _EmptyStorage()),
            ),
            projectsProvider.overrideWithValue(ProjectsState(const [])),
            reposProvider.overrideWithValue(ReposState(const [])),
            sessionsProvider.overrideWithValue(
              SessionsState([_session('s1', 'Session')]),
            ),
            chatItemsProvider('s1').overrideWithValue(const []),
            sessionMetaProvider('s1').overrideWithValue(null),
            sessionActionErrorProvider('s1').overrideWithValue(null),
            commandsProvider('s1').overrideWithValue(const []),
          ],
          child: const MaterialApp(home: SessionScreen(sessionId: 's1')),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Session actions'));
      await tester.pumpAndSettle();
    }

    testWidgets('the menu offers Session details', (tester) async {
      await pump(tester);
      expect(find.text('Session details'), findsOneWidget);
    });

    testWidgets('selecting Session details opens the panel', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Session details'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionIdentityDetails), findsOneWidget);
      expect(find.text(kAgentId), findsOneWidget);
    });
  });

  // ── desktop pane-header kebab (pane_header) ───────────────────────────────
  group('C2c — desktop pane-header door', () {
    Future<void> pump(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          connectionControllerProvider.overrideWith(
            (ref) => ConnectionController(const _EmptyStorage()),
          ),
          sessionsProvider.overrideWithValue(
            SessionsState([_session('s1', 'Session')]),
          ),
          reposProvider.overrideWithValue(ReposState(const [])),
          chatItemsProvider('s1').overrideWithValue(const []),
          sessionActionErrorProvider('s1').overrideWithValue(null),
          commandsProvider('s1').overrideWithValue(const []),
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
    }

    testWidgets('the kebab offers Session details', (tester) async {
      await pump(tester);
      expect(find.text('Session details'), findsOneWidget);
    });

    testWidgets('selecting Session details opens the panel', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Session details'));
      await tester.pumpAndSettle();
      expect(find.byType(SessionIdentityDetails), findsOneWidget);
      expect(find.text(kAgentId), findsOneWidget);
    });
  });

  // ── desktop tab menu (split_view) ─────────────────────────────────────────
  group('C2c — desktop tab menu', () {
    late _Clipboard clipboard;
    setUp(() {
      clipboard = _Clipboard();
      resetNodeIds();
    });

    Future<ProviderContainer> pumpTwoTabs(WidgetTester tester) async {
      final c = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(
            SessionsState([_session('s1', 'First'), _session('s2', 'Second')]),
          ),
          reposProvider.overrideWithValue(ReposState(const [])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
        ],
      );
      addTearDown(c.dispose);
      final ws = c.read(workspaceControllerProvider.notifier);
      ws.revealSession('s1');
      ws.revealSession('s2');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: Scaffold(body: WorkspaceView())),
        ),
      );
      await tester.pumpAndSettle();
      return c;
    }

    Finder chip(String label) => find
        .ancestor(of: find.text(label), matching: find.byType(Container))
        .first;

    testWidgets('offers Copy session id and NOT Session details (D13)', (
      tester,
    ) async {
      await pumpTwoTabs(tester);
      await tester.tap(chip('First'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Copy session id'), findsOneWidget);
      expect(
        find.text('Session details'),
        findsNothing,
        reason: 'the tab menu is a different job; the third door was cut (D13)',
      );
    });

    testWidgets('Copy session id copies the BARE id and opens no panel', (
      tester,
    ) async {
      clipboard.install(tester);
      addTearDown(() => clipboard.remove(tester));
      await pumpTwoTabs(tester);
      await tester.tap(chip('First'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy session id'));
      await tester.pumpAndSettle();
      // The MUTATION bites here: sessionIdentityText would be a multi-line
      // label:value payload, not the bare id.
      expect(clipboard.writes, [kAgentId]);
      expect(find.byType(SessionIdentityDetails), findsNothing);
    });
  });
}
