// Widget tests for SplitView's visual states: the focused-pane tonal surface
// (light + dark themes), the focused split's active-tab cap, full-height tab
// chips, and inactive-tab dimming. Runs headless with fake sessions, like
// split_tree_view_test.dart.
//
// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart' hide Tab, Split;
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/panes/split_node.dart';
import 'package:makit/desktop/chat/panes/workspace_controller.dart';
import 'package:makit/desktop/chat/split_tree_view.dart';
import 'package:makit/desktop/chat/split_view.dart';
import 'package:makit/store/models.dart';
import 'package:makit/store/store.dart';

const _model = ModelInfo(provider: 'openai', id: 'gpt-5', name: 'GPT-5');

Session _session(String id, String title) => Session(
  id: id,
  projectId: 'p1',
  agent: 'pi',
  title: title,
  status: SessionStatus.idle,
  policy: ApprovalPolicy.askOnRisky,
  lastPreview: '',
  lastActivityAt: 0,
  worktreePath: '/tmp/wt-a',
  branch: 'wt-a',
);

ProviderContainer _container({List<Session> sessions = const []}) {
  return ProviderContainer(
    overrides: [
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

Widget _tree(ProviderContainer c, {Brightness brightness = Brightness.light}) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.green,
            brightness: brightness,
          ),
        ),
        home: const Scaffold(body: WorkspaceView()),
      ),
    );

/// Pumps two side-by-side splits: pane A hosts s1 "Alpha", pane B hosts s2
/// "Beta". Pane B is the active (focused) split afterwards.
Future<ProviderContainer> _twoPanes(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
}) async {
  final c = _container(
    sessions: [_session('s1', 'Alpha'), _session('s2', 'Beta')],
  );
  addTearDown(c.dispose);
  _ws(c).revealSession('s1'); // pane A: s1
  _ws(c).divideActive(Axis.horizontal); // pane B (empty) active
  _ws(c).revealSession('s2'); // pane B: s2
  await tester.pumpWidget(_tree(c, brightness: brightness));
  await tester.pumpAndSettle();
  return c;
}

/// The body-background colour of the pane hosting the tab labelled [label]:
/// the outermost Container of that tab's SplitView.
Color? _paneColor(WidgetTester tester, String label) {
  final pane = find.ancestor(
    of: find.text(label),
    matching: find.byType(SplitView),
  );
  return tester
      .widget<Container>(
        find.descendant(of: pane, matching: find.byType(Container)).first,
      )
      .color;
}

/// The tab chip Container for the tab labelled [label] (its decoration carries
/// the cap border; its size is the rendered chip extent).
Finder _chip(WidgetTester tester, String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Container)).first;

Border _chipBorder(WidgetTester tester, String label) {
  final container = tester.widget<Container>(_chip(tester, label));
  return (container.decoration! as BoxDecoration).border! as Border;
}

ColorScheme _scheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(WorkspaceView))).colorScheme;

void main() {
  setUp(resetNodeIds);

  group('pane focus surfaces', () {
    testWidgets(
      'light theme: focused pane is one step lighter than unfocused panes',
      (tester) async {
        await _twoPanes(tester); // pane B ("Beta") focused
        final cs = _scheme(tester);

        expect(_paneColor(tester, 'Beta'), cs.surface);
        expect(_paneColor(tester, 'Alpha'), cs.surfaceContainerLow);
      },
    );

    testWidgets(
      'dark theme: focused pane is still the lighter (elevated) surface',
      (tester) async {
        await _twoPanes(tester, brightness: Brightness.dark);
        final cs = _scheme(tester);

        expect(cs.brightness, Brightness.dark);
        expect(_paneColor(tester, 'Beta'), cs.surfaceContainerLow);
        expect(_paneColor(tester, 'Alpha'), cs.surface);
      },
    );

    testWidgets('activating the other split moves the focused surface to it', (
      tester,
    ) async {
      final c = await _twoPanes(tester);
      final cs = _scheme(tester);

      final alphaSplitId = findTab(
        c.read(workspaceControllerProvider).root,
        's1',
      )!.$1;
      _ws(c).setActiveSplit(alphaSplitId);
      await tester.pumpAndSettle();

      expect(_paneColor(tester, 'Alpha'), cs.surface);
      expect(_paneColor(tester, 'Beta'), cs.surfaceContainerLow);
    });
  });

  group('tab chips', () {
    testWidgets('chips fill the tab bar\'s full height (no recessed gap)', (
      tester,
    ) async {
      await _twoPanes(tester);

      final chip = tester.getRect(_chip(tester, 'Alpha'));
      final bar = tester.getRect(
        find
            .ancestor(
              of: _chip(tester, 'Alpha'),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Container && (w.constraints?.hasTightHeight ?? false),
              ),
            )
            .first,
      );
      expect(chip.top, moreOrLessEquals(bar.top));
      expect(chip.bottom, moreOrLessEquals(bar.bottom));
    });

    testWidgets(
      'only the focused split\'s active tab gets the primary cap; the '
      'unfocused split\'s active tab caps stay neutral',
      (tester) async {
        final c = await _twoPanes(tester); // Beta's split focused
        final cs = _scheme(tester);

        final betaCap = _chipBorder(tester, 'Beta').top;
        expect(betaCap.color, cs.primary);
        expect(betaCap.width, 2);

        final alphaCap = _chipBorder(tester, 'Alpha').top;
        expect(alphaCap.color, cs.outlineVariant);

        // Focus follows the active split: activating Alpha's split moves the
        // primary cap over and dims Beta's.
        final alphaSplitId = findTab(
          c.read(workspaceControllerProvider).root,
          's1',
        )!.$1;
        _ws(c).setActiveSplit(alphaSplitId);
        await tester.pumpAndSettle();

        expect(_chipBorder(tester, 'Alpha').top.color, cs.primary);
        expect(_chipBorder(tester, 'Beta').top.color, cs.outlineVariant);
      },
    );

    testWidgets('the active tab seats on its pane surface; inactive tabs are '
        'dimmed', (tester) async {
      // One split with two tabs: s2 ("Second") active, s1 ("First") inactive.
      final c = _container(
        sessions: [_session('s1', 'First'), _session('s2', 'Second')],
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      _ws(c).revealSession('s2');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      final cs = _scheme(tester);

      // Active chip uses its (focused) pane's body surface; inactive chips
      // stay transparent on the recessed bar.
      Color? chipColor(String label) =>
          (tester.widget<Container>(_chip(tester, label)).decoration!
                  as BoxDecoration)
              .color;
      expect(chipColor('Second'), cs.surface);
      expect(chipColor('First'), Colors.transparent);

      // The inactive chip recedes behind a 0.55 opacity; the active one does
      // not.
      Iterable<double> opacitiesOf(String label) => tester
          .widgetList<Opacity>(
            find.ancestor(of: find.text(label), matching: find.byType(Opacity)),
          )
          .map((o) => o.opacity);
      expect(opacitiesOf('First'), contains(0.55));
      expect(opacitiesOf('Second'), isNot(contains(0.55)));
    });
  });

  group('tab context menu', () {
    // A single split with two tabs: s2 ("Second") active, s1 ("First")
    // inactive. The inactive tab's session pane is not built, so its label
    // appears only in the tab strip — an unambiguous right-click / long-press
    // target.
    Future<ProviderContainer> twoTabs(WidgetTester tester) async {
      final c = _container(
        sessions: [_session('s1', 'First'), _session('s2', 'Second')],
      );
      addTearDown(c.dispose);
      _ws(c).revealSession('s1');
      _ws(c).revealSession('s2');
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('right-click on a session tab opens the Rename menu', (
      tester,
    ) async {
      await twoTabs(tester);

      expect(find.text('Rename session'), findsNothing);
      await tester.tap(_chip(tester, 'First'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Rename session'), findsOneWidget);
    });

    testWidgets('long-press on a session tab opens the Rename menu', (
      tester,
    ) async {
      await twoTabs(tester);

      await tester.longPress(_chip(tester, 'First'));
      await tester.pumpAndSettle();
      expect(find.text('Rename session'), findsOneWidget);
    });

    testWidgets('selecting Rename opens the rename dialog seeded with the '
        'current title', (tester) async {
      await twoTabs(tester);

      await tester.tap(_chip(tester, 'First'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      // After right-click, the popup menu is open. Tap the Rename item.
      expect(find.text('Rename session'), findsOneWidget);
      await tester.tap(find.text('Rename session'));
      await tester.pumpAndSettle();

      // The /name client command shows a text dialog prefilled with the title.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Rename'), findsOneWidget);
      final dialogField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(dialogField).controller?.text, 'First');
    });

    testWidgets('the empty New tab has no context menu', (tester) async {
      final c = _container();
      addTearDown(c.dispose);
      await tester.pumpWidget(_tree(c));
      await tester.pumpAndSettle();

      expect(find.text('New'), findsOneWidget);
      await tester.tap(_chip(tester, 'New'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Rename session'), findsNothing);
    });
  });
}
