// Widget tests for the desktop split-pane view. These run headless under
// `flutter test` (no macOS engine needed) using the composer_e2e override
// recipe so each leaf's DesktopChatPane resolves a real fake session.
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/desktop/chat/keymap_scope.dart';
import 'package:makit/desktop/chat/panes/pane_node.dart';
import 'package:makit/desktop/chat/panes/pane_tree_controller.dart';
import 'package:makit/desktop/chat/panes/pane_tree_view.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/shortcuts/keymap_controller.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/composer/composer.dart';

Session _session() => Session(
  id: 's1',
  projectId: 'p1',
  agent: 'pi',
  title: 'Wire up pairing',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
);

Session _session2() => Session(
  id: 's2',
  projectId: 'p1',
  agent: 'pi',
  title: 'Second session',
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
);

const _model = ModelInfo(provider: 'openai', id: 'gpt-5', name: 'GPT-5');

ProviderContainer _container() {
  final c = ProviderContainer(
    overrides: [
      sessionsProvider.overrideWithValue(SessionsState([_session()])),
      eventsProvider.overrideWithValue(EventsState(const {}, const {})),
      sessionMetaProvider('s1').overrideWithValue(
        const SessionMeta(model: _model, thinking: 'medium', models: [_model]),
      ),
    ],
  );
  // Both leaves fall back to this global selection when their sessionId is
  // null, so every pane renders the fake session.
  c.read(selectedSessionProvider.notifier).state = 's1';
  return c;
}

/// A container with two distinct fake sessions (s1, s2) so two split panes can
/// each be bound to their own session.
ProviderContainer _twoSessionContainer() {
  final c = ProviderContainer(
    overrides: [
      sessionsProvider.overrideWithValue(
        SessionsState([_session(), _session2()]),
      ),
      eventsProvider.overrideWithValue(EventsState(const {}, const {})),
      sessionMetaProvider('s1').overrideWithValue(
        const SessionMeta(model: _model, thinking: 'medium', models: [_model]),
      ),
      sessionMetaProvider('s2').overrideWithValue(
        const SessionMeta(model: _model, thinking: 'medium', models: [_model]),
      ),
    ],
  );
  return c;
}

Widget _tree(ProviderContainer c) => UncontrolledProviderScope(
  container: c,
  child: const MaterialApp(home: Scaffold(body: PaneTreeView())),
);

void main() {
  group('DesktopChatPane header toggle', () {
    testWidgets('showHeader:false renders no in-pane header/actions menu', (
      tester,
    ) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: Scaffold(body: DesktopChatPane(showHeader: false)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(SessionActionsMenu),
        findsNothing,
        reason: 'no in-pane header when the tab strip owns it',
      );
    });

    testWidgets('showHeader:true renders the in-pane header + actions menu', (
      tester,
    ) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: Scaffold(body: DesktopChatPane())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SessionActionsMenu), findsOneWidget);
    });
  });

  group('PaneTreeView tab strip', () {
    testWidgets('single pane shows exactly one merged header (title+actions)', (
      tester,
    ) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      // The merged header shows the session title and its actions menu, and
      // there is no duplicate in-pane header (showHeader:false on the leaf).
      expect(find.text('Wire up pairing'), findsOneWidget);
      expect(find.byType(SessionActionsMenu), findsOneWidget);
    });

    testWidgets('splitting shows a merged header per pane', (tester) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      c
          .read(paneTreeControllerProvider.notifier)
          .splitActive(Axis.horizontal, pinnedSessionId: 's1');
      await tester.pumpAndSettle();

      // Two panes, each with its own merged header (title + actions menu). The
      // fresh pane falls back to the global selection, so it shows 's1' too.
      expect(find.text('Wire up pairing'), findsNWidgets(2));
      expect(find.byType(SessionActionsMenu), findsNWidgets(2));
    });
  });

  group('multi-pane composer focus', () {
    testWidgets(
      'two panes bound to different sessions each mount an independently '
      'focusable composer',
      (tester) async {
        final c = _twoSessionContainer();
        addTearDown(c.dispose);
        final ctrl = c.read(paneTreeControllerProvider.notifier);
        // Bind the original pane to s1, split, then bind the fresh pane to s2 —
        // two live sessions side-by-side, each with its own docked composer.
        ctrl.bindActiveSession('s1');
        ctrl.splitActive(Axis.horizontal, pinnedSessionId: 's1');
        ctrl.bindActiveSession('s2');

        await tester.pumpWidget(_tree(c));
        await tester.pumpAndSettle();

        // Both leaves render a Composer with its OWN text field bound to its
        // OWN focus node. The defect is an app-lifetime singleton FocusNode
        // shared by every pane: two live panes then bind two text fields to
        // one node (illegal double-attach; focus becomes undefined).
        final composers = find.byType(Composer);
        expect(composers, findsNWidgets(2));
        final fields = find.descendant(
          of: composers,
          matching: find.byType(EditableText),
        );
        expect(fields, findsNWidgets(2));

        final firstNode = tester.widget<EditableText>(fields.first).focusNode;
        final lastNode = tester.widget<EditableText>(fields.last).focusNode;
        expect(
          identical(firstNode, lastNode),
          isFalse,
          reason: 'each pane must own a distinct composer FocusNode',
        );

        // Each field is independently focusable: focusing one pane's composer
        // does not steal or mirror focus in the other.
        await tester.tap(fields.first);
        await tester.pumpAndSettle();
        expect(firstNode.hasPrimaryFocus, isTrue);
        expect(lastNode.hasPrimaryFocus, isFalse);

        await tester.tap(fields.last);
        await tester.pumpAndSettle();
        expect(lastNode.hasPrimaryFocus, isTrue);
        expect(firstNode.hasPrimaryFocus, isFalse);

        // And each is independently typable: text stays in the pane it was
        // entered in.
        await tester.enterText(fields.first, 'left pane text');
        await tester.enterText(fields.last, 'right pane text');
        await tester.pumpAndSettle();
        expect(
          tester.widget<EditableText>(fields.first).controller.text,
          'left pane text',
        );
        expect(
          tester.widget<EditableText>(fields.last).controller.text,
          'right pane text',
        );
      },
    );

    testWidgets(
      'per-pane composer text survives a divider resize (panes keyed by id, '
      'not remounted)',
      (tester) async {
        final c = _twoSessionContainer();
        addTearDown(c.dispose);
        final ctrl = c.read(paneTreeControllerProvider.notifier);
        ctrl.bindActiveSession('s1');
        ctrl.splitActive(Axis.horizontal, pinnedSessionId: 's1');
        ctrl.bindActiveSession('s2');

        await tester.pumpWidget(_tree(c));
        await tester.pumpAndSettle();

        final fields = find.descendant(
          of: find.byType(Composer),
          matching: find.byType(EditableText),
        );
        await tester.enterText(fields.first, 'left pane text');
        await tester.enterText(fields.last, 'right pane text');
        await tester.pumpAndSettle();

        // Resize the split. Keying the split view by object identity (rather
        // than its id) would remount the whole subtree here, dropping both
        // composers' text; keying by id keeps each pane's State intact.
        final split = c.read(paneTreeControllerProvider).root as PaneSplit;
        ctrl.adjustRatio(split.id, 0.1);
        await tester.pumpAndSettle();

        final after = find.descendant(
          of: find.byType(Composer),
          matching: find.byType(EditableText),
        );
        expect(
          tester.widget<EditableText>(after.first).controller.text,
          'left pane text',
        );
        expect(
          tester.widget<EditableText>(after.last).controller.text,
          'right pane text',
        );
      },
    );
  });

  group('focus-composer shortcut targets the active leaf', () {
    // A deterministic control-based keymap so the chord is Ctrl+L regardless of
    // the host platform the test runs on.
    final keymapOverride = keymapProvider.overrideWith(
      (ref) => KeymapController.ephemeral(cmdIsPrimary: false),
    );

    Widget keymapTree(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        home: Scaffold(
          body: DesktopKeymapScope(
            onOpenSettings: () {},
            child: const PaneTreeView(),
          ),
        ),
      ),
    );

    // Sends the platform-independent Ctrl+L focus-composer chord.
    Future<void> pressFocusComposer(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('focuses the active session pane composer', (tester) async {
      final c = ProviderContainer(
        overrides: [
          keymapOverride,
          sessionsProvider.overrideWithValue(SessionsState([_session()])),
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
      c.read(selectedSessionProvider.notifier).state = 's1';

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
        reason: 'composer starts unfocused (the scope holds focus)',
      );

      await pressFocusComposer(tester);

      expect(
        tester.widget<EditableText>(field).focusNode.hasPrimaryFocus,
        isTrue,
        reason: 'the shortcut focuses the active leaf composer',
      );
    });

    testWidgets('focuses a worktree-start pane composer', (tester) async {
      // The active leaf hosts a sessionless worktree draft (WorktreeStartView),
      // whose Composer must be bound to the leaf's desktopComposerFocusProvider
      // node for the shortcut to reach it (SPEC-14 per-leaf focus fix).
      final c = ProviderContainer(
        overrides: [
          keymapOverride,
          sessionsProvider.overrideWithValue(SessionsState(const [])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
          agentsProvider.overrideWith((ref) async => const <AgentDescriptor>[]),
        ],
      );
      addTearDown(c.dispose);
      c.read(selectedWorktreeProvider.notifier).state = const SelectedWorktree(
        projectId: 'p1',
        path: '/tmp/wt',
        branch: 'feature',
      );

      await tester.pumpWidget(keymapTree(c));
      await tester.pumpAndSettle();

      // The worktree-start view renders its own docked composer.
      final field = find.descendant(
        of: find.byType(Composer),
        matching: find.byType(EditableText),
      );
      expect(field, findsOneWidget);
      expect(
        tester.widget<EditableText>(field).focusNode.hasPrimaryFocus,
        isFalse,
      );

      await pressFocusComposer(tester);

      expect(
        tester.widget<EditableText>(field).focusNode.hasPrimaryFocus,
        isTrue,
        reason:
            'the shortcut focuses the worktree-start pane composer via the '
            'per-leaf focus node',
      );
    });
  });

  group('divider', () {
    testWidgets('dragging the divider updates the split ratio', (tester) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      c
          .read(paneTreeControllerProvider.notifier)
          .splitActive(Axis.horizontal, pinnedSessionId: 's1');
      await tester.pumpAndSettle();

      expect((c.read(paneTreeControllerProvider).root as PaneSplit).ratio, 0.5);

      // A horizontal split lays out side-by-side with a VerticalDivider strip.
      await tester.drag(find.byType(VerticalDivider), const Offset(-120, 0));
      await tester.pumpAndSettle();

      final ratio =
          (c.read(paneTreeControllerProvider).root as PaneSplit).ratio;
      expect(
        ratio,
        lessThan(0.5),
        reason: 'dragging the divider left shrinks the first pane',
      );
      expect(ratio, greaterThanOrEqualTo(kMinPaneRatio));
    });
  });

  group('close button', () {
    testWidgets('closing the last pane is a no-op', (tester) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      expect(c.read(paneTreeControllerProvider).root, isA<PaneLeaf>());
      await tester.tap(find.byTooltip('Close pane'));
      await tester.pumpAndSettle();

      expect(
        c.read(paneTreeControllerProvider).root,
        isA<PaneLeaf>(),
        reason: 'the sole pane cannot be closed',
      );
    });

    testWidgets('closing one of two panes collapses back to a single pane', (
      tester,
    ) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      c
          .read(paneTreeControllerProvider.notifier)
          .splitActive(Axis.horizontal, pinnedSessionId: 's1');
      await tester.pumpAndSettle();
      expect(c.read(paneTreeControllerProvider).root, isA<PaneSplit>());

      // Two close buttons now; tapping either collapses the split.
      await tester.tap(find.byTooltip('Close pane').first);
      await tester.pumpAndSettle();

      expect(c.read(paneTreeControllerProvider).root, isA<PaneLeaf>());
    });
  });

  group('pane header interactions', () {
    testWidgets('tapping a pane header activates that pane', (tester) async {
      final c = _container();
      addTearDown(c.dispose);
      c
          .read(paneTreeControllerProvider.notifier)
          .splitActive(Axis.horizontal, pinnedSessionId: 's1');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      // The fresh (second) pane is active after a split; focus the first pane
      // by clicking its header title. Guards the regression where the header's
      // opaque GestureDetector swallowed the tap and focus never moved.
      final firstLeaf =
          (c.read(paneTreeControllerProvider).root as PaneSplit).first
              as PaneLeaf;
      expect(
        c.read(paneTreeControllerProvider).activeLeafId,
        isNot(firstLeaf.id),
      );
      await tester.tap(find.text('Wire up pairing').first);
      await tester.pumpAndSettle();
      expect(c.read(paneTreeControllerProvider).activeLeafId, firstLeaf.id);
    });

    testWidgets('clicking into a pane body (composer) activates that pane', (
      tester,
    ) async {
      // Guards the misrouting bug: submitting bound the new session to the
      // *active* leaf, but clicking into another pane's composer never made
      // that pane active (the TextField won the gesture arena), so messages
      // landed in a different pane than the one being typed in.
      final c = _container();
      addTearDown(c.dispose);
      c
          .read(paneTreeControllerProvider.notifier)
          .splitActive(Axis.horizontal, pinnedSessionId: 's1');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      final firstLeaf =
          (c.read(paneTreeControllerProvider).root as PaneSplit).first
              as PaneLeaf;
      expect(
        c.read(paneTreeControllerProvider).activeLeafId,
        isNot(firstLeaf.id),
      );
      // Click into the first pane's composer text field (pane body, not the
      // header) — that pane must become active so sends/binds route to it.
      await tester.tap(find.byType(EditableText).first);
      await tester.pumpAndSettle();
      expect(c.read(paneTreeControllerProvider).activeLeafId, firstLeaf.id);
    });

    testWidgets('only the active pane falls back to the global selection', (
      tester,
    ) async {
      final c = _container();
      addTearDown(c.dispose);
      final ctrl = c.read(paneTreeControllerProvider.notifier);
      // Fresh pane (null session) is active; the original is pinned to s1.
      ctrl.splitActive(Axis.horizontal, pinnedSessionId: 's1');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      // Focus the pinned pane, leaving the fresh (null) pane inactive.
      final split = c.read(paneTreeControllerProvider).root as PaneSplit;
      final pinned = [
        split.first,
        split.second,
      ].cast<PaneLeaf>().firstWhere((l) => l.sessionId == 's1');
      ctrl.setActive(pinned.id);
      await tester.pumpAndSettle();

      // The inactive null pane no longer mirrors the global selection: it shows
      // the empty-pane title, and only the pinned pane shows the session.
      expect(find.text('Empty pane'), findsOneWidget);
      expect(find.text('Wire up pairing'), findsOneWidget);
    });
    testWidgets(
      'pane header exposes a11y: move semantics + 24px close target',
      (tester) async {
        final c = _container();
        addTearDown(c.dispose);
        await tester.pumpWidget(_tree(c));
        await tester.pumpAndSettle();

        // The draggable grip is labelled for assistive tech as "Move pane".
        expect(
          find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == 'Move pane',
          ),
          findsOneWidget,
        );
        // Close button meets the 24px minimum interactive target.
        final closeBtn = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.close),
        );
        expect(closeBtn.constraints?.minHeight, greaterThanOrEqualTo(24.0));
        expect(closeBtn.constraints?.minWidth, greaterThanOrEqualTo(24.0));
      },
    );
  });

  group('global fallback gating', () {
    testWidgets('a non-tracking pane ignores the global worktree draft', (
      tester,
    ) async {
      final c = ProviderContainer(
        overrides: [
          sessionsProvider.overrideWithValue(SessionsState(const [])),
          eventsProvider.overrideWithValue(EventsState(const {}, const {})),
        ],
      );
      addTearDown(c.dispose);
      // A worktree draft is selected globally.
      c.read(selectedWorktreeProvider.notifier).state = const SelectedWorktree(
        projectId: 'p1',
        path: '/tmp/wt',
        branch: 'main',
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(
            home: Scaffold(
              body: DesktopChatPane(
                showHeader: false,
                trackGlobalSelection: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Not tracking the global selection → no worktree start view; the pane
      // stays empty rather than mirroring the global worktree draft.
      expect(find.text('Select or start a session'), findsOneWidget);
    });
  });

  group('sessionless-worktree split', () {
    testWidgets(
      'a worktree-bound pane shows its harness picker even when a session is '
      'globally selected (no master-chat bleed-through)',
      (tester) async {
        // Reproduces the report: after a split, desktop auto-select refills the
        // global selectedSession with the master; a worktree-bound pane must
        // still show ITS harness picker, not the master conversation.
        const wt = SelectedWorktree(
          projectId: 'p1',
          path: '/tmp/wt',
          branch: 'b',
        );
        final c = ProviderContainer(
          overrides: [
            sessionsProvider.overrideWithValue(SessionsState([_session()])),
            eventsProvider.overrideWithValue(EventsState(const {}, const {})),
            sessionMetaProvider('s1').overrideWithValue(
              const SessionMeta(
                model: _model,
                thinking: 'medium',
                models: [_model],
              ),
            ),
            agentsProvider.overrideWith(
              (ref) async => const <AgentDescriptor>[],
            ),
          ],
        );
        addTearDown(c.dispose);
        c.read(selectedSessionProvider.notifier).state = 's1';

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: const MaterialApp(
              home: Scaffold(
                body: DesktopChatPane(
                  worktree: wt,
                  showHeader: false,
                  trackGlobalSelection: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The pane's own worktree binding wins over the global session.
        expect(find.byType(WorktreeStartView), findsOneWidget);
      },
    );

    testWidgets(
      'double-split from a session keeps the session pane and makes every '
      'worktree pane a harness picker (no dead pane, no mirroring)',
      (tester) async {
        const wt = SelectedWorktree(
          projectId: 'p1',
          path: '/tmp/wt',
          branch: 'b',
        );
        final c = ProviderContainer(
          overrides: [
            sessionsProvider.overrideWithValue(SessionsState([_session()])),
            eventsProvider.overrideWithValue(EventsState(const {}, const {})),
            sessionMetaProvider('s1').overrideWithValue(
              const SessionMeta(
                model: _model,
                thinking: 'medium',
                models: [_model],
              ),
            ),
            agentsProvider.overrideWith(
              (ref) async => const <AgentDescriptor>[],
            ),
          ],
        );
        addTearDown(c.dispose);
        final ctrl = c.read(paneTreeControllerProvider.notifier);
        // Reproduce the report: in session s1, ⌘D (→ s1 pane + worktree pane),
        // then ⌘D again from the worktree pane (→ two worktree panes). Each
        // step binds its pane explicitly, exactly as _splitPane does.
        ctrl.bindActiveSession('s1');
        ctrl.splitActive(Axis.horizontal, pinnedSessionId: 's1');
        ctrl.bindActiveWorktree(wt);
        c.read(selectedWorktreeProvider.notifier).state = wt;
        ctrl.splitActive(Axis.horizontal, pinnedWorktree: wt);
        ctrl.bindActiveWorktree(wt);

        await tester.pumpWidget(_tree(c));
        await tester.pumpAndSettle();

        // Both worktree panes render a harness picker; neither falls into the
        // dead "Select or start a session" state, and the session pane stays.
        expect(find.byType(WorktreeStartView), findsNWidgets(2));
        expect(find.text('Select or start a session'), findsNothing);
      },
    );
  });
}
