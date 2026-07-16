// Widget tests for the desktop split-pane view. These run headless under
// `flutter test` (no macOS engine needed) using the composer_e2e override
// recipe so each leaf's DesktopChatPane resolves a real fake session.
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/desktop_chat_pane.dart';
import 'package:makit/desktop/chat/panes/pane_node.dart';
import 'package:makit/desktop/chat/panes/pane_tree_controller.dart';
import 'package:makit/desktop/chat/panes/pane_tree_view.dart';
import 'package:makit/desktop/chat/selected_session.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

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
        final closeButtonFinder = find.byType(IconButton).last;
        final closeSize = tester.getSize(closeButtonFinder);
        expect(closeSize.height, greaterThanOrEqualTo(24.0));
        expect(closeSize.width, greaterThanOrEqualTo(24.0));
      },
    );
  });
}
