// Widget tests for the SPEC-28 desktop/iPad workspace view (Split/Tab model).
// These run headless under `flutter test` (no macOS engine) using fake sessions
// so each tab's DesktopChatPane resolves a real transcript + composer.
//
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/desktop/chat/keymap_scope.dart';
import 'package:makit/desktop/chat/open_in_ide.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/desktop/chat/split_tree_view.dart';
import 'package:makit/desktop/chat/split_view.dart' show TabDragData;
import 'package:makit/shortcuts/keymap_controller.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/transport/protocol.dart';
import 'package:makit/ui/composer/composer.dart';

/// A connection whose `session.kill` completes only when the test says so.
class _KillConnection extends ConnectionController {
  _KillConnection() : super(const _NoStore());

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

class _NoStore implements SecureStore {
  const _NoStore();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

const _model = ModelInfo(provider: 'openai', id: 'gpt-5', name: 'GPT-5');

Session _session(String id, String title, {String worktree = '/tmp/wt-a'}) =>
    Session(
      id: id,
      projectId: 'p1',
      agent: 'pi',
      title: title,
      status: SessionStatus.idle,
      policy: ApprovalPolicy.askOnRisky,
      lastPreview: '',
      lastActivityAt: 0,
      worktreePath: worktree,
      branch: worktree.split('/').last,
    );

ProviderContainer _container({
  List<Session> sessions = const [],
  ConnectionController? connection,
}) {
  return ProviderContainer(
    overrides: [
      if (connection != null)
        connectionControllerProvider.overrideWith((ref) => connection),
      sessionsProvider.overrideWithValue(SessionsState(sessions)),
      eventsProvider.overrideWithValue(EventsState(const {}, const {})),
      for (final s in sessions)
        sessionMetaProvider(s.id).overrideWithValue(
          const SessionMeta(
            model: _model,
            thinking: 'medium',
            models: [_model],
          ),
        ),
    ],
  );
}

WorkspaceController _ws(ProviderContainer c) =>
    c.read(workspaceControllerProvider.notifier);

Widget _tree(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: const MaterialApp(home: Scaffold(body: WorkspaceView())),
);

void main() {
  setUp(resetNodeIds);

  group('empty placeholder (decision 7)', () {
    testWidgets('a fresh workspace shows the empty starter tab + placeholder', (
      tester,
    ) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      expect(
        find.text('New'),
        findsOneWidget,
        reason: 'empty tab labelled New',
      );
      expect(find.text('Select a session, or start a new one'), findsOneWidget);
      expect(find.byType(EmptyPaneStarter), findsOneWidget);
    });
  });

  group('reveal (decision 6) + tab switching', () {
    testWidgets('revealing a session binds it into the active tab', (
      tester,
    ) async {
      final c = _container(sessions: [_session('s1', 'Wire up pairing')]);
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      _ws(c).revealSession('s1');
      await tester.pumpAndSettle();

      expect(find.text('Wire up pairing'), findsOneWidget); // tab label
      expect(find.byType(Composer), findsOneWidget); // its body
      expect(c.read(selectedSessionProvider), 's1');
    });

    testWidgets('revealing an already-open session focuses it (no duplicate)', (
      tester,
    ) async {
      final c = _container(
        sessions: [_session('s1', 'First'), _session('s2', 'Second')],
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      _ws(c).revealSession('s2'); // two tabs in one split, s2 active
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      expect(c.read(selectedSessionProvider), 's2');

      // Revealing s1 again just focuses its existing tab.
      _ws(c).revealSession('s1');
      await tester.pumpAndSettle();
      expect(c.read(selectedSessionProvider), 's1');
      // s1 still appears exactly once in the tree.
      expect(
        findTab(c.read(workspaceControllerProvider).root, 's1'),
        isNotNull,
      );
    });

    testWidgets('tapping a tab switches the active tab', (tester) async {
      final c = _container(
        sessions: [_session('s1', 'First'), _session('s2', 'Second')],
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      _ws(c).revealSession('s2');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      expect(c.read(selectedSessionProvider), 's2');

      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      expect(c.read(selectedSessionProvider), 's1');
    });
  });

  group('cross-worktree coexistence (decision 3)', () {
    testWidgets('sessions from different worktrees coexist as tabs in one '
        'split', (tester) async {
      final c = _container(
        sessions: [
          _session('s1', 'Alpha', worktree: '/tmp/wt-a'),
          _session('s2', 'Beta', worktree: '/tmp/wt-b'),
        ],
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      _ws(c).revealSession('s2');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      // Both tabs live in the one worktree-agnostic split.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(c.read(workspaceControllerProvider).root, isA<Split>());
    });
  });

  group('close (empty-split invariant)', () {
    testWidgets(
      'closing the last tab of a split collapses it into the sibling',
      (tester) async {
        final c = _container(sessions: [_session('s1', 'Kept')]);
        addTearDown(c.dispose);
        _ws(c).revealSession('s1'); // split A: s1
        _ws(c).divideActive(Axis.horizontal); // split B (empty) active
        await tester.pumpWidget(_tree(c));
        await tester.pumpAndSettle();
        expect(c.read(workspaceControllerProvider).root, isA<Splitter>());

        // The active split (B) has a single empty tab; closing it collapses B.
        await tester.tap(find.byTooltip('Close tab').last);
        await tester.pumpAndSettle();

        expect(c.read(workspaceControllerProvider).root, isA<Split>());
        expect(c.read(selectedSessionProvider), 's1');
      },
    );

    testWidgets('closing the last tab of the sole split resets it to a starter '
        'tab (never empty)', (tester) async {
      final c = _container(sessions: [_session('s1', 'Wire up pairing')]);
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      expect(c.read(selectedSessionProvider), 's1');

      await tester.tap(find.byTooltip('Close tab'));
      await tester.pumpAndSettle();

      // The sole split can never fully close: it resets to an empty starter
      // tab. The session itself is not killed (still in the store).
      final root = c.read(workspaceControllerProvider).root as Split;
      expect(root.tabs, hasLength(1));
      expect(root.tabs.single.sessionId, isNull);
      expect(find.byType(EmptyPaneStarter), findsOneWidget);
      expect(c.read(sessionsProvider).byId('s1'), isNotNull);
    });
  });

  group('divider', () {
    testWidgets('dragging the divider updates the splitter ratio', (
      tester,
    ) async {
      final c = _container(sessions: [_session('s1', 'One')]);
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      _ws(c).divideActive(Axis.horizontal);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      expect((c.read(workspaceControllerProvider).root as Splitter).ratio, 0.5);

      await tester.drag(find.byType(VerticalDivider), const Offset(-120, 0));
      await tester.pumpAndSettle();

      final ratio =
          (c.read(workspaceControllerProvider).root as Splitter).ratio;
      expect(ratio, lessThan(0.5));
      expect(ratio, greaterThanOrEqualTo(kMinPaneRatio));
    });
  });

  group('quit', () {
    testWidgets('Quit closes the tab and kills the session', (tester) async {
      final conn = _KillConnection();
      final c = _container(
        sessions: [_session('s1', 'Wire up pairing')],
        connection: conn,
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Session actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quit session'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Quit'));
      await tester.pumpAndSettle();

      // Optimistic: the sole split reset to an empty starter tab before the
      // kill resolved.
      expect(conn.killCompleted.isCompleted, isFalse);
      expect(c.read(selectedSessionProvider), isNull);
      expect(find.byType(EmptyPaneStarter), findsOneWidget);

      conn.killCompleted.complete(const {});
      await tester.pumpAndSettle();
    });
  });

  group('multi-tab composer focus', () {
    testWidgets('two splits each mount an independently focusable composer', (
      tester,
    ) async {
      final c = _container(
        sessions: [_session('s1', 'First'), _session('s2', 'Second')],
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      _ws(c).divideActive(Axis.horizontal);
      _ws(c).revealSession('s2');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      final composers = find.byType(Composer);
      expect(composers, findsNWidgets(2));
      final fields = find.descendant(
        of: composers,
        matching: find.byType(EditableText),
      );
      expect(fields, findsNWidgets(2));

      final firstNode = tester.widget<EditableText>(fields.first).focusNode;
      final lastNode = tester.widget<EditableText>(fields.last).focusNode;
      expect(identical(firstNode, lastNode), isFalse);

      await tester.tap(fields.first);
      await tester.pumpAndSettle();
      expect(firstNode.hasPrimaryFocus, isTrue);
      expect(lastNode.hasPrimaryFocus, isFalse);

      await tester.enterText(fields.first, 'left');
      await tester.enterText(fields.last, 'right');
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(fields.first).controller.text, 'left');
      expect(tester.widget<EditableText>(fields.last).controller.text, 'right');
    });
  });

  group('drag affordances', () {
    testWidgets('each split exposes a "Move split" grip and draggable tabs', (
      tester,
    ) async {
      final c = _container(sessions: [_session('s1', 'One')]);
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'Move split',
        ),
        findsOneWidget,
      );
      // The session tab is itself draggable (into another group / a new split).
      expect(find.byType(Draggable<TabDragData>), findsOneWidget);
    });
  });

  group('drag & drop (gestures)', () {
    // Drives a Draggable→DragTarget drop: press on [from], move toward [to] in
    // steps so the Draggable starts and the target registers onMove at the
    // final position, then release.
    Future<void> dragDrop(WidgetTester tester, Finder from, Offset to) async {
      final start = tester.getCenter(from);
      final g = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 30));
      final mid = Offset((start.dx + to.dx) / 2, (start.dy + to.dy) / 2);
      await g.moveTo(mid);
      await tester.pump(const Duration(milliseconds: 30));
      await g.moveTo(to);
      await tester.pump(const Duration(milliseconds: 30));
      await g.moveTo(to);
      await tester.pump(const Duration(milliseconds: 30));
      await g.up();
      await tester.pumpAndSettle();
    }

    List<String> sessionOrder(ProviderContainer c, String splitId) {
      final split = firstSplitWhere(
        c.read(workspaceControllerProvider).root,
        (s) => s.id == splitId ? s : null,
      )!;
      return [
        for (final t in split.tabs)
          if (t.sessionId != null) t.sessionId!,
      ];
    }

    Split? splitById(ProviderContainer c, String id) => firstSplitWhere(
      c.read(workspaceControllerProvider).root,
      (s) => s.id == id ? s : null,
    );

    Future<ProviderContainer> twoPanes(WidgetTester tester) async {
      final c = _container(
        sessions: [_session('s1', 'Alpha'), _session('s2', 'Beta')],
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1'); // pane A: s1
      _ws(c).divideActive(Axis.horizontal); // pane B (empty) active
      _ws(c).revealSession('s2'); // pane B: s2
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('dropping a tab on another pane\'s body moves it into that '
        'group', (tester) async {
      final c = await twoPanes(tester);
      expect(c.read(workspaceControllerProvider).root, isA<Splitter>());

      // Drag pane B's tab (Beta) onto pane A's body centre.
      final paneA = tester.getCenter(find.byType(DesktopChatPane).first);
      await dragDrop(tester, find.text('Beta'), paneA);

      final root = c.read(workspaceControllerProvider).root;
      expect(root, isA<Split>(), reason: 'emptied pane B collapsed away');
      expect(findTab(root, 's1'), isNotNull);
      expect(findTab(root, 's2'), isNotNull);
    });

    testWidgets(
      'dropping a tab near a pane edge detaches it into a new split',
      (tester) async {
        final c = _container(
          sessions: [_session('s1', 'Alpha'), _session('s2', 'Beta')],
        );
        addTearDown(c.dispose);
        _ws(c).revealSession('s1');
        _ws(c).revealSession('s2'); // one pane, tabs [s1, s2]
        await tester.pumpWidget(_tree(c));
        await tester.pumpAndSettle();
        expect(c.read(workspaceControllerProvider).root, isA<Split>());

        // Drag Beta to the right edge of the pane.
        final rect = tester.getRect(find.byType(DesktopChatPane));
        await dragDrop(
          tester,
          find.text('Beta'),
          Offset(rect.right - 6, rect.center.dy),
        );

        final ctrl = c.read(workspaceControllerProvider);
        expect(
          ctrl.root,
          isA<Splitter>(),
          reason: 'Beta detached into a split',
        );
        expect(splitById(c, ctrl.activeSplitId)!.tabs.single.sessionId, 's2');
      },
    );

    testWidgets('dropping a tab on another pane\'s tab reorders into it', (
      tester,
    ) async {
      final c = await twoPanes(tester);
      final first = findTab(c.read(workspaceControllerProvider).root, 's1')!.$1;

      // Drop Beta onto the Alpha tab chip → insert at Alpha's index (0).
      await dragDrop(
        tester,
        find.text('Beta'),
        tester.getCenter(find.text('Alpha')),
      );

      expect(c.read(workspaceControllerProvider).root, isA<Split>());
      expect(sessionOrder(c, first), ['s2', 's1']);
    });
  });

  group('window title bar (worktree + IDE launcher)', () {
    testWidgets(
      'shows the active worktree branch and an Open-in-IDE launcher',
      (tester) async {
        final c = _container(
          sessions: [_session('s1', 'Alpha', worktree: '/tmp/wt-a')],
        );
        addTearDown(c.dispose);
        _ws(c).revealSession('s1');
        await tester.pumpWidget(_tree(c));
        await tester.pumpAndSettle();

        expect(
          find.text('wt-a'),
          findsOneWidget,
          reason: 'branch context label',
        );
        expect(find.byType(OpenInIdeButton), findsOneWidget);
      },
    );

    testWidgets('empty starter tab shows no worktree title or IDE launcher', (
      tester,
    ) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      expect(find.byType(OpenInIdeButton), findsNothing);
    });
  });

  group('focus-composer shortcut targets the active tab', () {
    final keymapOverride = keymapProvider.overrideWith(
      (ref) => KeymapController.ephemeral(cmdIsPrimary: false),
    );

    Widget keymapTree(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: DesktopKeymapScope(
            onOpenSettings: () {},
            child: const WorkspaceView(),
          ),
        ),
      ),
    );

    testWidgets('Ctrl+L focuses the active tab composer', (tester) async {
      final c = ProviderContainer(
        overrides: [
          keymapOverride,
          sessionsProvider.overrideWithValue(
            SessionsState([_session('s1', 'One')]),
          ),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
          sessionMetaProvider('s1').overrideWithValue(
            const SessionMeta(
              model: _model,
              thinking: 'medium',
              models: [_model],
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.read(workspaceControllerProvider.notifier).revealSession('s1');

      await tester.pumpWidget(keymapTree(c));
      await tester.pumpAndSettle();

      final field = find.descendant(
        of: find.byType(Composer),
        matching: find.byType(EditableText),
      );
      expect(field, findsOneWidget);
      expect(
        tester.widget<EditableText>(field).focusNode.hasPrimaryFocus,
        isFalse,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(
        tester.widget<EditableText>(field).focusNode.hasPrimaryFocus,
        isTrue,
      );
    });
  });
}
